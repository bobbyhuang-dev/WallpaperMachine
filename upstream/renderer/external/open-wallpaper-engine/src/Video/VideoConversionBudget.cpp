#include "Video/VideoConversionBudget.hpp"

#include <algorithm>
#include <limits>

namespace wallpaper::video
{
namespace
{

constexpr std::size_t RefusalIndex(VideoConversionRefusal refusal)
{
    return static_cast<std::size_t>(refusal);
}

/// Sums that saturate instead of wrapping. A wrapped total reads as a small
/// number, and a small number answers "fits" for a size that cannot possibly
/// fit.
constexpr std::uint64_t SatAdd(std::uint64_t lhs, std::uint64_t rhs)
{
    constexpr std::uint64_t limit = std::numeric_limits<std::uint64_t>::max();
    return lhs > limit - rhs ? limit : lhs + rhs;
}

constexpr std::uint64_t SatAdd(std::uint64_t a, std::uint64_t b, std::uint64_t c)
{
    return SatAdd(SatAdd(a, b), c);
}

/// Differences that stop at zero. Every subtraction here removes bytes the
/// ledger was told about, so an underflow would be a bookkeeping bug turning
/// into an astronomically large total.
constexpr std::uint64_t SatSub(std::uint64_t lhs, std::uint64_t rhs)
{
    return lhs > rhs ? lhs - rhs : 0;
}

} // namespace

const char* VideoConversionRefusalName(VideoConversionRefusal refusal)
{
    switch (refusal) {
    case VideoConversionRefusal::None: return "none";
    case VideoConversionRefusal::StillOnLoan: return "still on loan";
    case VideoConversionRefusal::AlreadyPooled: return "already pooled";
    case VideoConversionRefusal::SlotExceedsCeiling: return "slot exceeds ceiling";
    case VideoConversionRefusal::AllocationUnsatisfiable: return "allocation unsatisfiable";
    case VideoConversionRefusal::MemoryPressure: return "memory pressure";
    case VideoConversionRefusal::LiveAllocationAtCeiling: return "live allocation at ceiling";
    }
    return "unknown";
}

VideoConversionBudget::VideoConversionBudget(std::uint64_t ceiling_bytes)
    : m_ceiling_bytes(ceiling_bytes)
{
    m_pooled.reserve(kCoexistingSlots);
    m_live.reserve(kCoexistingSlots);
}

VideoConversionBudget::~VideoConversionBudget()
{
    if (m_domain != nullptr) m_domain->Forget(this);
}

std::uint64_t VideoConversionBudget::RequiredBytesForAllSlots(std::uint64_t slot_bytes)
{
    constexpr std::uint64_t limit = std::numeric_limits<std::uint64_t>::max();
    if (slot_bytes == 0) return 0;
    // A wrapped product reads as a small number, which would answer "fits" for
    // a size that cannot possibly fit.
    if (slot_bytes > limit / kCoexistingSlots) return limit;
    return slot_bytes * kCoexistingSlots;
}

bool VideoConversionBudget::HostsAllSlots(std::uint64_t slot_bytes) const
{
    return RequiredBytesForAllSlots(slot_bytes) <= m_ceiling_bytes;
}

std::uint64_t VideoConversionBudget::refusals(VideoConversionRefusal refusal) const
{
    return m_refusals_by_reason[RefusalIndex(refusal)];
}

std::uint64_t VideoConversionBudget::total_live_conversion_allocation_bytes() const
{
    return SatAdd(m_available_cached_bytes, m_checked_out_bytes, m_awaiting_gpu_bytes);
}

std::uint64_t VideoConversionBudget::ImmovableBytes() const
{
    return SatAdd(m_checked_out_bytes, m_awaiting_gpu_bytes, m_reserved_estimate_bytes);
}

std::uint64_t VideoConversionBudget::AcquireEffectiveCeiling(std::uint64_t reserved_after)
{
    if (m_domain == nullptr) return m_ceiling_bytes;
    // One locked domain call: this budget's post-operation reservation is
    // recorded by the same call that computes the answer, so no other budget
    // can be told these bytes are still free.
    const std::uint64_t headroom = m_domain->AcquireHeadroom(
        this, total_live_conversion_allocation_bytes(), m_available_cached_bytes, reserved_after);
    return std::min(m_ceiling_bytes, headroom);
}

void VideoConversionBudget::NoteLiveTotal()
{
    const std::uint64_t live = total_live_conversion_allocation_bytes();
    if (live > m_peak_live_bytes) m_peak_live_bytes = live;
    if (m_available_cached_bytes > m_peak_available_cached_bytes) {
        m_peak_available_cached_bytes = m_available_cached_bytes;
    }
}

void VideoConversionBudget::PublishToDomain() const
{
    if (m_domain == nullptr) return;
    m_domain->Publish(this,
                      total_live_conversion_allocation_bytes(),
                      m_available_cached_bytes,
                      m_reserved_estimate_bytes);
}

void VideoConversionBudget::AttachDomain(VideoConversionMemoryDomain* domain)
{
    if (m_domain == domain) return;
    if (m_domain != nullptr) m_domain->Forget(this);
    m_domain = domain;
    PublishToDomain();
}

void VideoConversionBudget::SetInFlightSlotCap(std::uint32_t slots)
{
    // The floor is what a pool serving one video texture needs, so a pool that
    // never publishes a count reports exactly as it did before this existed.
    m_in_flight_slot_cap = std::max(slots, kCoexistingSlots);
    // Raising the threshold past what is in flight ends the reporting episode
    // for the same reason returning a destination does: the condition no
    // longer holds, so the next breach is a genuinely new one and is reported
    // rather than silently swallowed. Lowering it neither reclaims nor refuses
    // anything already in flight; it only changes what the next reservation is
    // counted as.
    if (m_live.size() < static_cast<std::size_t>(m_in_flight_slot_cap)) {
        m_in_flight_cap_reported = false;
    }
}

void* VideoConversionBudget::Take(const VideoConversionSlotKey& key)
{
    for (std::size_t i = 0; i < m_pooled.size(); ++i) {
        if (! (m_pooled[i].key == key)) continue;
        void*               resource = m_pooled[i].resource;
        const std::uint64_t bytes = m_pooled[i].bytes;
        m_available_cached_bytes = SatSub(m_available_cached_bytes, bytes);
        m_pooled.erase(m_pooled.begin() + static_cast<std::ptrdiff_t>(i));
        // Available -> CheckedOut. The bytes stay on the live books: the
        // destination still exists, it is merely no longer reusable.
        m_live.push_back({ resource, bytes, LiveState::CheckedOut });
        m_checked_out_bytes = SatAdd(m_checked_out_bytes, bytes);
        ++m_hits;
        NoteLiveTotal();
        PublishToDomain();
        return resource;
    }
    ++m_misses;
    return nullptr;
}

VideoConversionReservation VideoConversionBudget::ReserveAllocation(
    const VideoConversionSlotKey& key,
    std::uint64_t                 estimated_bytes,
    std::vector<void*>&           evicted)
{
    VideoConversionReservation reservation;
    reservation.estimated_bytes = estimated_bytes;

    // The one denial, taken before anything else is examined and without
    // booking an estimate. An allocation of this size already failed, so it
    // was never going to produce a destination: denying it withholds nothing
    // the consumer would otherwise have received and cannot suppress the
    // release a later request depends on, which is why the deadlock argument
    // against a capacity refusal does not reach this path. The import fails
    // either way; what this removes is a futile allocation attempt and a log
    // line, once per frame, for as long as the condition lasts. Nothing here
    // touches the in-flight threshold, its counter or its episode.
    if (m_unsatisfiable_bytes != 0 && estimated_bytes >= m_unsatisfiable_bytes) {
        ++m_unsatisfiable_denials;
        reservation.refusal = VideoConversionRefusal::AllocationUnsatisfiable;
        if (! m_unsatisfiable_reported) {
            m_unsatisfiable_reported = true;
            reservation.first_unsatisfiable_report = true;
        }
        return reservation;
    }

    // Granted otherwise, before anything else is looked at. There is no
    // capacity refusal here at all: the caller has already decoded the frame,
    // and the one capacity refusal this ever had — the in-flight threshold —
    // deadlocked the return it was waiting for, because the consumer holds its
    // last imported destination until a new import replaces it. See
    // `in_flight_cap_breaches()` for the measurement.
    reservation.granted = true;

    // The threshold is a reported quantity. It is checked on destinations in
    // flight, never on cached ones: those have already been returned and are
    // what the next import reuses, so counting them would report a breach
    // exactly when reuse is working.
    if (m_live.size() >= static_cast<std::size_t>(m_in_flight_slot_cap)) {
        ++m_in_flight_cap_breaches;
        reservation.in_flight_cap_breached = true;
        // Once per episode, so a caller that asks every frame reports the
        // condition once instead of once per frame.
        if (! m_in_flight_cap_reported) {
            m_in_flight_cap_reported = true;
            reservation.first_in_flight_cap_report = true;
        }
    }

    // Book the intent before asking, so the domain answer this budget acts on
    // already accounts for it and no other budget is told these bytes are
    // free. `ImmovableBytes()` therefore includes `estimated_bytes` below.
    m_reserved_estimate_bytes = SatAdd(m_reserved_estimate_bytes, estimated_bytes);
    const std::uint64_t ceiling = AcquireEffectiveCeiling(m_reserved_estimate_bytes);

    // Only this budget's own cache can be given up. Nothing else in the
    // process is touched, whatever the domain total says.
    while (! m_pooled.empty() &&
           SatAdd(m_available_cached_bytes, ImmovableBytes()) > ceiling) {
        const std::size_t victim = ChooseVictim(key);
        if (victim == m_pooled.size()) break;
        Evict(victim, evicted);
    }

    // The cache is as small as this budget can make it. If the request still
    // does not fit, it is granted anyway: the frame is already decoded and
    // refusing here drops it. The overshoot is reported instead, and what
    // bounds it is the structural quantity stated at `in_flight_cap_breaches()`
    // — which this budget reports breaches of and deliberately does not
    // enforce.
    reservation.over_ceiling = SatAdd(m_available_cached_bytes, ImmovableBytes()) > ceiling;
    if (reservation.over_ceiling) ++m_over_ceiling_grants;
    // Republish the post-eviction cache so the other budgets see what this one
    // actually gave up.
    PublishToDomain();
    return reservation;
}

void VideoConversionBudget::CommitAllocation(const VideoConversionReservation& reservation,
                                             const VideoConversionSlot&        slot)
{
    if (! reservation.granted) return;
    // The estimate has done its job; the measured cost replaces it.
    m_reserved_estimate_bytes = SatSub(m_reserved_estimate_bytes, reservation.estimated_bytes);
    if (slot.resource == nullptr || slot.bytes == 0) {
        PublishToDomain();
        return;
    }
    for (auto& live : m_live) {
        if (live.resource != slot.resource) continue;
        // A handle the ledger already tracks is re-measured, never billed a
        // second time.
        if (live.state == LiveState::CheckedOut) {
            m_checked_out_bytes = SatAdd(SatSub(m_checked_out_bytes, live.bytes), slot.bytes);
        } else {
            m_awaiting_gpu_bytes = SatAdd(SatSub(m_awaiting_gpu_bytes, live.bytes), slot.bytes);
        }
        live.bytes = slot.bytes;
        NoteLiveTotal();
        PublishToDomain();
        return;
    }
    m_live.push_back({ slot.resource, slot.bytes, LiveState::CheckedOut });
    m_checked_out_bytes = SatAdd(m_checked_out_bytes, slot.bytes);
    NoteLiveTotal();
    PublishToDomain();
}

void VideoConversionBudget::CancelReservation(const VideoConversionReservation& reservation)
{
    if (! reservation.granted) return;
    m_reserved_estimate_bytes = SatSub(m_reserved_estimate_bytes, reservation.estimated_bytes);
    PublishToDomain();
}

void VideoConversionBudget::MarkAwaitingGpu(void* resource)
{
    if (resource == nullptr) return;
    for (auto& live : m_live) {
        if (live.resource != resource || live.state != LiveState::CheckedOut) continue;
        m_checked_out_bytes = SatSub(m_checked_out_bytes, live.bytes);
        m_awaiting_gpu_bytes = SatAdd(m_awaiting_gpu_bytes, live.bytes);
        live.state = LiveState::AwaitingGpu;
        PublishToDomain();
        return;
    }
}

bool VideoConversionBudget::ReportGpuComplete(void* resource)
{
    for (std::size_t i = 0; i < m_live.size(); ++i) {
        if (m_live[i].resource != resource) continue;
        // The handle leaves the ledger outright. The caller now owns it and
        // either offers it back through `Admit` or releases it; billing it
        // here as well would count the same bytes twice.
        if (m_live[i].state == LiveState::CheckedOut) {
            m_checked_out_bytes = SatSub(m_checked_out_bytes, m_live[i].bytes);
        } else {
            m_awaiting_gpu_bytes = SatSub(m_awaiting_gpu_bytes, m_live[i].bytes);
        }
        m_live.erase(m_live.begin() + static_cast<std::ptrdiff_t>(i));
        // A returned destination ends the in-flight-cap episode, so a genuinely
        // new one is reported again rather than staying silent forever.
        if (m_live.size() < static_cast<std::size_t>(m_in_flight_slot_cap)) {
            m_in_flight_cap_reported = false;
        }
        PublishToDomain();
        return true;
    }
    return false;
}

void VideoConversionBudget::EndLoan(void* resource) { (void)ReportGpuComplete(resource); }

VideoConversionAdmission VideoConversionBudget::Refuse(VideoConversionRefusal refusal)
{
    ++m_refusals;
    ++m_refusals_by_reason[RefusalIndex(refusal)];
    return { false, refusal };
}

void VideoConversionBudget::Evict(std::size_t index, std::vector<void*>& evicted)
{
    evicted.push_back(m_pooled[index].resource);
    m_available_cached_bytes = SatSub(m_available_cached_bytes, m_pooled[index].bytes);
    m_pooled.erase(m_pooled.begin() + static_cast<std::ptrdiff_t>(index));
    ++m_evictions;
}

std::size_t VideoConversionBudget::ChooseVictim(const VideoConversionSlotKey& key) const
{
    std::size_t victim = m_pooled.size();
    for (std::size_t i = 0; i < m_pooled.size(); ++i) {
        if (victim == m_pooled.size()) {
            victim = i;
            continue;
        }
        const bool candidate_reusable = m_pooled[i].key == key;
        const bool victim_reusable = m_pooled[victim].key == key;
        // A shape this request cannot use is worth less than one it can, so it
        // goes first however recently it was pooled.
        if (candidate_reusable != victim_reusable) {
            if (! candidate_reusable) victim = i;
            continue;
        }
        if (m_pooled[i].sequence < m_pooled[victim].sequence) victim = i;
    }
    return victim;
}

bool VideoConversionBudget::CachesReusableSlot(const VideoConversionSlotKey& key) const
{
    for (const auto& pooled : m_pooled) {
        if (pooled.key == key) return true;
    }
    return false;
}

VideoConversionAdmission VideoConversionBudget::Admit(const VideoConversionSlot& slot,
                                                      std::vector<void*>&        evicted)
{
    if (slot.resource == nullptr || slot.bytes == 0) {
        return Refuse(VideoConversionRefusal::SlotExceedsCeiling);
    }
    for (const auto& live : m_live) {
        if (live.resource == slot.resource) return Refuse(VideoConversionRefusal::StillOnLoan);
    }
    for (const auto& pooled : m_pooled) {
        if (pooled.resource == slot.resource) {
            return Refuse(VideoConversionRefusal::AlreadyPooled);
        }
    }
    if (m_memory_pressure) return Refuse(VideoConversionRefusal::MemoryPressure);
    if (m_unsatisfiable_bytes != 0 && slot.bytes >= m_unsatisfiable_bytes) {
        return Refuse(VideoConversionRefusal::AllocationUnsatisfiable);
    }
    // A size that cannot fit this budget's own ceiling can never be cached, so
    // it is refused before anything is spent to make room for it.
    if (slot.bytes > m_ceiling_bytes) {
        return Refuse(VideoConversionRefusal::SlotExceedsCeiling);
    }

    const std::uint64_t ceiling = AcquireEffectiveCeiling(m_reserved_estimate_bytes);
    // Admission does not allocate: the destination already exists, and the
    // caller releases it the moment this refuses. So the first cached slot of
    // the shape being admitted costs nothing at peak — it is precisely the
    // destination the next import would allocate — and refusing it buys one
    // allocate/free pair per frame and not one byte. Only a *second* idle slot
    // of a shape whose in-flight bytes already fill the ceiling is
    // speculative: it bets on more concurrency than the ceiling admits. That
    // is the one this refuses, and it refuses before evicting anything, so the
    // slot already proven reusable stays cached.
    if (CachesReusableSlot(slot.key) && SatAdd(ImmovableBytes(), slot.bytes) > ceiling) {
        return Refuse(VideoConversionRefusal::LiveAllocationAtCeiling);
    }

    while (m_pooled.size() >= kCoexistingSlots ||
           SatAdd(m_available_cached_bytes, ImmovableBytes(), slot.bytes) > ceiling) {
        const std::size_t victim = ChooseVictim(slot.key);
        if (victim == m_pooled.size()) break;
        Evict(victim, evicted);
    }

    m_pooled.push_back({ slot.key, slot.bytes, slot.resource, ++m_sequence });
    m_available_cached_bytes = SatAdd(m_available_cached_bytes, slot.bytes);
    ++m_admissions;
    NoteLiveTotal();
    PublishToDomain();
    return { true, VideoConversionRefusal::None };
}

void VideoConversionBudget::DropOtherKeys(const VideoConversionSlotKey& key,
                                          std::vector<void*>&           evicted)
{
    for (std::size_t i = m_pooled.size(); i != 0; --i) {
        const std::size_t index = i - 1;
        if (m_pooled[index].key == key) continue;
        Evict(index, evicted);
    }
    PublishToDomain();
}

void VideoConversionBudget::Drain(std::vector<void*>& evicted)
{
    // `m_pooled` only ever holds Available slots, so nothing the GPU may still
    // be reading can be reclaimed here.
    while (! m_pooled.empty()) Evict(m_pooled.size() - 1, evicted);
    PublishToDomain();
}

void VideoConversionBudget::ReportAllocationFailure(std::uint64_t       slot_bytes,
                                                    std::vector<void*>& evicted)
{
    if (slot_bytes != 0 &&
        (m_unsatisfiable_bytes == 0 || slot_bytes < m_unsatisfiable_bytes)) {
        m_unsatisfiable_bytes = slot_bytes;
    }
    Drain(evicted);
}

void VideoConversionBudget::ReportMemoryPressure(std::vector<void*>& evicted)
{
    m_memory_pressure = true;
    Drain(evicted);
}

void VideoConversionBudget::ClearMemoryPressure() { m_memory_pressure = false; }

void VideoConversionBudget::Reset()
{
    m_memory_pressure = false;
    // The recorded size goes, so a size that was being denied is attempted
    // again, and both reporting episodes start over.
    m_unsatisfiable_bytes = 0;
    m_unsatisfiable_reported = false;
    m_in_flight_cap_reported = false;
}

VideoConversionMemoryDomain::VideoConversionMemoryDomain(std::uint64_t ceiling_bytes)
    : m_ceiling_bytes(ceiling_bytes)
{
}

std::uint64_t VideoConversionMemoryDomain::HeadroomLocked(const void* budget) const
{
    std::uint64_t others = 0;
    for (const auto& entry : m_entries) {
        if (entry.budget == budget) continue;
        // A granted estimate is about to become an allocation, so it takes
        // room from everyone else exactly as an allocation does. Counting only
        // `live` here is what would let two pools spend the same bytes.
        others = SatAdd(others, SatAdd(entry.live, entry.reserved));
    }
    if (others >= m_ceiling_bytes) return 0;
    return m_ceiling_bytes - others;
}

void VideoConversionMemoryDomain::RecordLocked(const void*   budget,
                                               std::uint64_t live_bytes,
                                               std::uint64_t cached_bytes,
                                               std::uint64_t reserved_bytes)
{
    std::uint64_t total = 0;
    bool          found = false;
    for (auto& entry : m_entries) {
        if (entry.budget == budget) {
            entry.live = live_bytes;
            entry.cached = cached_bytes;
            entry.reserved = reserved_bytes;
            found = true;
        }
        total = SatAdd(total, entry.live);
    }
    if (! found) {
        m_entries.push_back({ budget, live_bytes, cached_bytes, reserved_bytes });
        total = SatAdd(total, live_bytes);
    }
    // The peak tracks allocations. Estimates are intents and may never become
    // allocations, so a peak that included them would not be a peak of
    // anything that existed.
    if (total > m_peak_live_bytes) m_peak_live_bytes = total;
}

void VideoConversionMemoryDomain::Publish(const void*   budget,
                                          std::uint64_t live_bytes,
                                          std::uint64_t cached_bytes,
                                          std::uint64_t reserved_bytes)
{
    if (budget == nullptr) return;
    const std::lock_guard<std::mutex> lock(m_mutex);
    RecordLocked(budget, live_bytes, cached_bytes, reserved_bytes);
}

std::uint64_t VideoConversionMemoryDomain::AcquireHeadroom(const void*   budget,
                                                           std::uint64_t live_bytes,
                                                           std::uint64_t cached_bytes,
                                                           std::uint64_t reserved_bytes)
{
    if (budget == nullptr) return m_ceiling_bytes;
    const std::lock_guard<std::mutex> lock(m_mutex);
    // Record first, then answer, under one lock. The caller's new reservation
    // is therefore visible to the next budget that asks, which is the only
    // thing that stops two pools from being told the same bytes are free.
    RecordLocked(budget, live_bytes, cached_bytes, reserved_bytes);
    const std::uint64_t headroom = HeadroomLocked(budget);
    if (headroom == 0) {
        // The other budgets alone have reached the ceiling, so this one is
        // being asked to give up whatever it can. It still cannot be made to
        // release a destination the GPU is reading, which is why shedding is
        // partial as well as late.
        ++m_shed_requests;
    }
    return headroom;
}

void VideoConversionMemoryDomain::Forget(const void* budget)
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    for (std::size_t i = 0; i < m_entries.size(); ++i) {
        if (m_entries[i].budget != budget) continue;
        m_entries.erase(m_entries.begin() + static_cast<std::ptrdiff_t>(i));
        return;
    }
}

std::uint64_t VideoConversionMemoryDomain::ceiling_bytes() const
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    return m_ceiling_bytes;
}

std::uint64_t VideoConversionMemoryDomain::live_bytes() const
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    std::uint64_t                     total = 0;
    for (const auto& entry : m_entries) total = SatAdd(total, entry.live);
    return total;
}

std::uint64_t VideoConversionMemoryDomain::peak_live_bytes() const
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    return m_peak_live_bytes;
}

std::uint64_t VideoConversionMemoryDomain::cached_bytes() const
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    std::uint64_t                     total = 0;
    for (const auto& entry : m_entries) total = SatAdd(total, entry.cached);
    return total;
}

std::uint64_t VideoConversionMemoryDomain::reserved_bytes() const
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    std::uint64_t                     total = 0;
    for (const auto& entry : m_entries) total = SatAdd(total, entry.reserved);
    return total;
}

std::uint64_t VideoConversionMemoryDomain::headroom_for(const void* budget) const
{
    // A pure query: it records nothing and counts nothing, so reading it from
    // a diagnostic cannot move a number an operation is judged by. The
    // operations that act on the answer use `AcquireHeadroom`.
    const std::lock_guard<std::mutex> lock(m_mutex);
    return HeadroomLocked(budget);
}

std::uint64_t VideoConversionMemoryDomain::shed_requests() const
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    return m_shed_requests;
}

std::size_t VideoConversionMemoryDomain::budget_count() const
{
    const std::lock_guard<std::mutex> lock(m_mutex);
    return m_entries.size();
}

VideoConversionMemoryDomain& SharedVideoConversionMemoryDomain()
{
    static VideoConversionMemoryDomain domain;
    return domain;
}

} // namespace wallpaper::video
