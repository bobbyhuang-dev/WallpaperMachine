#include "Video/VideoConversionBudget.hpp"

#include <limits>

namespace wallpaper::video
{
namespace
{

constexpr std::size_t RefusalIndex(VideoConversionRefusal refusal)
{
    return static_cast<std::size_t>(refusal);
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
    }
    return "unknown";
}

VideoConversionBudget::VideoConversionBudget(std::uint64_t ceiling_bytes)
    : m_ceiling_bytes(ceiling_bytes)
{
    m_pooled.reserve(kCoexistingSlots);
    m_on_loan.reserve(kCoexistingSlots);
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

void* VideoConversionBudget::Take(const VideoConversionSlotKey& key)
{
    for (std::size_t i = 0; i < m_pooled.size(); ++i) {
        if (! (m_pooled[i].key == key)) continue;
        void* resource = m_pooled[i].resource;
        m_pooled_bytes -= m_pooled[i].bytes;
        m_pooled.erase(m_pooled.begin() + static_cast<std::ptrdiff_t>(i));
        m_on_loan.push_back(resource);
        ++m_hits;
        return resource;
    }
    ++m_misses;
    return nullptr;
}

bool VideoConversionBudget::ReportGpuComplete(void* resource)
{
    for (std::size_t i = 0; i < m_on_loan.size(); ++i) {
        if (m_on_loan[i] != resource) continue;
        m_on_loan.erase(m_on_loan.begin() + static_cast<std::ptrdiff_t>(i));
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
    m_pooled_bytes -= m_pooled[index].bytes;
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

VideoConversionAdmission VideoConversionBudget::Admit(const VideoConversionSlot& slot,
                                                      std::vector<void*>&        evicted)
{
    if (slot.resource == nullptr || slot.bytes == 0) {
        return Refuse(VideoConversionRefusal::SlotExceedsCeiling);
    }
    for (void* loaned : m_on_loan) {
        if (loaned == slot.resource) return Refuse(VideoConversionRefusal::StillOnLoan);
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
    if (slot.bytes > m_ceiling_bytes) {
        return Refuse(VideoConversionRefusal::SlotExceedsCeiling);
    }

    while (m_pooled.size() >= kCoexistingSlots ||
           m_pooled_bytes > m_ceiling_bytes - slot.bytes) {
        const std::size_t victim = ChooseVictim(slot.key);
        if (victim == m_pooled.size()) break;
        Evict(victim, evicted);
    }

    m_pooled.push_back({ slot.key, slot.bytes, slot.resource, ++m_sequence });
    m_pooled_bytes += slot.bytes;
    if (m_pooled_bytes > m_peak_pooled_bytes) m_peak_pooled_bytes = m_pooled_bytes;
    ++m_admissions;
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
}

void VideoConversionBudget::Drain(std::vector<void*>& evicted)
{
    while (! m_pooled.empty()) Evict(m_pooled.size() - 1, evicted);
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
    m_unsatisfiable_bytes = 0;
}

} // namespace wallpaper::video
