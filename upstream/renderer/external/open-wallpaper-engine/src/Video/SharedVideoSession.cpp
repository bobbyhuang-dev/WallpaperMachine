#include "SharedVideoSession.hpp"

#include "FfmpegVideoTextureSource.hpp"
#include "Image.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper
{
namespace video
{
namespace
{

std::atomic<bool> g_shared_decode_enabled { false };

/// Playback rates closer than this are the same rate. Rates reach a source as
/// floats that have been through user settings and per-scene speed multipliers,
/// so an exact comparison would split sessions over representation error alone.
constexpr float kRateEquivalenceEpsilon = 1e-3f;

bool SameRate(float lhs, float rhs) {
    return std::fabs(lhs - rhs) <= kRateEquivalenceEpsilon;
}

/// Identity of the media a session decodes.
///
/// The project-relative name is deliberately not part of it and must never be
/// used alone: two unrelated wallpapers both containing a file called
/// "video.mp4" would collide, and one display would show the other's video.
/// The canonical path plus size and modification time are content identity —
/// a file replaced in place produces a different key, so a new decoder is
/// opened instead of a stale one being reused.
struct MediaIdentity {
    std::string   canonical_path;
    std::uint64_t size_bytes { 0 };
    std::int64_t  modified_ns { 0 };

    [[nodiscard]] bool valid() const { return ! canonical_path.empty(); }

    [[nodiscard]] std::string key() const {
        return canonical_path + '\0' + std::to_string(size_bytes) + '\0' +
               std::to_string(modified_ns);
    }
};

std::optional<MediaIdentity> IdentifyMedia(const std::string& media_path) {
    if (media_path.empty()) return std::nullopt;
    std::error_code ec;
    const auto      canonical = std::filesystem::canonical(media_path, ec);
    if (ec) return std::nullopt;
    const auto size = std::filesystem::file_size(canonical, ec);
    if (ec) return std::nullopt;
    const auto modified = std::filesystem::last_write_time(canonical, ec);
    if (ec) return std::nullopt;

    return MediaIdentity {
        canonical.string(),
        static_cast<std::uint64_t>(size),
        static_cast<std::int64_t>(modified.time_since_epoch().count()),
    };
}

class SharedVideoSession;

/// A running decoder plus the consumers currently reading it.
class SharedVideoSession {
public:
    struct Consumer {
        std::uint64_t      id { 0 };
        VideoPlaybackState state {};
        bool               has_state { false };
    };

    SharedVideoSession(MediaIdentity identity, std::shared_ptr<VideoTextureSource> source)
        : m_identity(std::move(identity)), m_source(std::move(source)) {}

    [[nodiscard]] const MediaIdentity& identity() const { return m_identity; }
    [[nodiscard]] VideoTextureSource&  source() const { return *m_source; }

    void addConsumer(std::uint64_t id) {
        std::lock_guard lock(m_mutex);
        m_consumers.push_back(Consumer { id, {}, false });
    }

    /// Returns true when the last consumer left, so the registry can drop the
    /// session and with it the decoder.
    bool removeConsumer(std::uint64_t id) {
        std::lock_guard lock(m_mutex);
        m_consumers.erase(std::remove_if(m_consumers.begin(),
                                         m_consumers.end(),
                                         [id](const Consumer& c) { return c.id == id; }),
                          m_consumers.end());
        if (m_driver_id == id) m_driver_id = 0;
        return m_consumers.empty();
    }

    [[nodiscard]] std::size_t consumerCount() const {
        std::lock_guard lock(m_mutex);
        return m_consumers.size();
    }

    /// Whether this consumer can keep sharing at the requested rate.
    ///
    /// A lone consumer always can: there is no other timeline to disturb. A
    /// paused consumer imposes no rate either, because it is not reading new
    /// frames.
    [[nodiscard]] bool accepts(std::uint64_t id, const VideoPlaybackState& state) const {
        std::lock_guard lock(m_mutex);
        if (m_consumers.size() <= 1) return true;
        if (state.paused) return true;
        for (const auto& consumer : m_consumers) {
            if (consumer.id == id) continue;
            if (! consumer.has_state || consumer.state.paused) continue;
            if (! SameRate(consumer.state.rate, state.rate)) return false;
        }
        return true;
    }

    bool syncPlayback(std::uint64_t id, const VideoPlaybackState& state, std::string* error) {
        VideoPlaybackState effective {};
        {
            std::lock_guard lock(m_mutex);
            for (auto& consumer : m_consumers) {
                if (consumer.id != id) continue;
                consumer.state     = state;
                consumer.has_state = true;
                break;
            }

            // The decoder has one clock, so exactly one consumer may move it.
            // Electing a driver and ignoring everyone else's elapsed time stops
            // two surfaces whose scene clocks differ slightly from seeking the
            // shared decoder back and forth every frame.
            if (m_driver_id == 0 || ! isActiveLocked(m_driver_id)) {
                m_driver_id = electDriverLocked();
            }

            effective.paused = allPausedLocked();
            effective.rate   = effectiveRateLocked(state.rate);
            effective.scene_elapsed_seconds =
                driverElapsedLocked().value_or(state.scene_elapsed_seconds);

            if (m_driver_id != id && m_has_forwarded && m_forwarded.paused == effective.paused &&
                SameRate(m_forwarded.rate, effective.rate)) {
                // A non-driving consumer that changed nothing the session acts
                // on. Forwarding would only re-base the decoder's clock.
                return true;
            }
            m_forwarded     = effective;
            m_has_forwarded = true;
        }
        return m_source->syncPlayback(effective, error);
    }

    bool refreshFrame(std::string* error) {
        // Promotion is bounded by the clock the driver set, so a second
        // consumer asking within the same tick finds nothing left to promote.
        // That is why this is cheap rather than a second decode.
        return m_source->refreshFrame(error);
    }

private:
    [[nodiscard]] bool isActiveLocked(std::uint64_t id) const {
        return std::any_of(m_consumers.begin(), m_consumers.end(), [id](const Consumer& c) {
            return c.id == id && c.has_state && ! c.state.paused;
        });
    }

    [[nodiscard]] std::uint64_t electDriverLocked() const {
        for (const auto& consumer : m_consumers) {
            if (consumer.has_state && ! consumer.state.paused) return consumer.id;
        }
        // Everyone is paused: keep whichever consumer reported state first so
        // the timeline does not jump when playback resumes.
        for (const auto& consumer : m_consumers) {
            if (consumer.has_state) return consumer.id;
        }
        return m_consumers.empty() ? 0 : m_consumers.front().id;
    }

    [[nodiscard]] bool allPausedLocked() const {
        bool any_state = false;
        for (const auto& consumer : m_consumers) {
            if (! consumer.has_state) continue;
            any_state = true;
            if (! consumer.state.paused) return false;
        }
        return any_state;
    }

    [[nodiscard]] float effectiveRateLocked(float fallback) const {
        for (const auto& consumer : m_consumers) {
            if (consumer.has_state && ! consumer.state.paused) return consumer.state.rate;
        }
        return fallback;
    }

    [[nodiscard]] std::optional<double> driverElapsedLocked() const {
        for (const auto& consumer : m_consumers) {
            if (consumer.id == m_driver_id && consumer.has_state) {
                return consumer.state.scene_elapsed_seconds;
            }
        }
        return std::nullopt;
    }

    mutable std::mutex                  m_mutex;
    MediaIdentity                       m_identity;
    std::shared_ptr<VideoTextureSource> m_source;
    std::vector<Consumer>               m_consumers;
    std::uint64_t                       m_driver_id { 0 };
    VideoPlaybackState                  m_forwarded {};
    bool                                m_has_forwarded { false };
};

/// One consumer's view of a session.
///
/// Every call a surface makes goes through its own handle, so the session can
/// tell consumers apart: which drives the clock, which are paused, and how many
/// remain. Each handle also keeps its own retained frame, which is what lets one
/// surface pause on the frame it was showing while another keeps advancing.
class SharedVideoSourceHandle final : public VideoTextureSource {
public:
    SharedVideoSourceHandle(std::shared_ptr<SharedVideoSession> session, std::uint64_t consumer_id)
        : m_session(std::move(session)), m_consumer_id(consumer_id) {}

    ~SharedVideoSourceHandle() override;

    bool prime(std::string* error) override {
        auto current = session();
        return current && current->source().prime(error);
    }

    bool syncPlayback(const VideoPlaybackState& state, std::string* error) override;

    bool refreshFrame(std::string* error) override;

    [[nodiscard]] VideoTextureFrame currentFrame() const override {
        std::lock_guard lock(m_mutex);
        return m_held;
    }

    [[nodiscard]] bool retainCurrentFrame(VideoTextureFrame* out) const override {
        if (out == nullptr) return false;
        std::lock_guard lock(m_mutex);
        if (! m_has_held) return false;
        RetainAppleVideoFrame(m_held, out);
        return true;
    }

    [[nodiscard]] double durationSeconds() const override {
        auto current = session();
        return current ? current->source().durationSeconds() : 0.0;
    }

    [[nodiscard]] double playbackSeconds() const override {
        auto current = session();
        return current ? current->source().playbackSeconds() : 0.0;
    }

    [[nodiscard]] uint64_t loopCount() const override {
        auto current = session();
        return current ? current->source().loopCount() : 0;
    }

    [[nodiscard]] double frameDurationSeconds() const override {
        auto current = session();
        return current ? current->source().frameDurationSeconds() : 0.0;
    }

    [[nodiscard]] VideoSourceStats sourceStats() const override {
        auto current = session();
        if (! current) return {};
        // Deliberately the underlying decoder's identity and totals, not this
        // handle's. Two surfaces sharing one decoder report one instance_id,
        // which is what lets a global total dedupe them instead of counting one
        // decode twice.
        return current->source().sourceStats();
    }

private:
    [[nodiscard]] std::shared_ptr<SharedVideoSession> session() const {
        std::lock_guard lock(m_mutex);
        return m_session;
    }

    mutable std::mutex                  m_mutex;
    std::shared_ptr<SharedVideoSession> m_session;
    const std::uint64_t                 m_consumer_id;
    /// This consumer's own reference on the frame it is showing. Independent of
    /// the decoder's current frame, so promotion on another surface's thread
    /// cannot free the buffer this one is importing.
    VideoTextureFrame                   m_held {};
    bool                                m_has_held { false };
    bool                                m_paused { false };
};

/// Process-wide registry of live sessions.
class SharedVideoRegistry {
public:
    static SharedVideoRegistry& Instance() {
        static SharedVideoRegistry instance;
        return instance;
    }

    std::shared_ptr<VideoTextureSource> acquire(const Image& image, std::string* error) {
        // Sharing needs a file on disk: an in-memory payload cannot be reopened
        // for a later split, and its identity is not a path. Those stay private,
        // which is the behaviour that existed before this registry.
        auto identity = IdentifyMedia(image.videoFilePath);
        if (! SharedVideoDecodeEnabled() || ! identity.has_value()) {
            return CreateVideoTextureSource(image, error);
        }

        const auto    key         = identity->key();
        const auto    consumer_id = m_next_consumer_id.fetch_add(1) + 1;
        std::lock_guard lock(m_mutex);
        auto            existing = m_sessions.find(key);
        if (existing != m_sessions.end()) {
            existing->second->addConsumer(consumer_id);
            return std::make_shared<SharedVideoSourceHandle>(existing->second, consumer_id);
        }

        auto source = CreateVideoTextureSource(image, error);
        if (! source) return {};
        auto session = std::make_shared<SharedVideoSession>(*identity, std::move(source));
        session->addConsumer(consumer_id);
        m_sessions.emplace(key, session);
        return std::make_shared<SharedVideoSourceHandle>(std::move(session), consumer_id);
    }

    /// Moves one consumer off a shared session onto a private decoder, used
    /// when it asks for a playback rate the shared timeline is not running at.
    ///
    /// Returns null when a private decoder cannot be opened; the caller then
    /// keeps the shared one, because a wrong rate is better than no video.
    std::shared_ptr<SharedVideoSession> detach(const std::shared_ptr<SharedVideoSession>& from,
                                               std::uint64_t consumer_id) {
        auto source =
            std::make_shared<FfmpegVideoTextureSource>(from->identity().canonical_path);
        std::string error;
        if (! source->prime(&error)) return {};

        auto session = std::make_shared<SharedVideoSession>(from->identity(), std::move(source));
        session->addConsumer(consumer_id);
        {
            std::lock_guard lock(m_mutex);
            m_detached.push_back(session);
        }
        release(from, consumer_id);
        return session;
    }

    void release(const std::shared_ptr<SharedVideoSession>& session, std::uint64_t consumer_id) {
        if (! session) return;
        if (! session->removeConsumer(consumer_id)) return;
        std::lock_guard lock(m_mutex);
        auto            it = m_sessions.find(session->identity().key());
        if (it != m_sessions.end() && it->second == session) m_sessions.erase(it);
        m_detached.erase(std::remove(m_detached.begin(), m_detached.end(), session),
                         m_detached.end());
    }

    void releaseIdle() {
        std::lock_guard lock(m_mutex);
        for (auto it = m_sessions.begin(); it != m_sessions.end();) {
            if (it->second->consumerCount() == 0) {
                it = m_sessions.erase(it);
            } else {
                ++it;
            }
        }
        m_detached.erase(std::remove_if(m_detached.begin(),
                                        m_detached.end(),
                                        [](const auto& s) { return s->consumerCount() == 0; }),
                         m_detached.end());
    }

    [[nodiscard]] std::uint32_t sessionCount() const {
        std::lock_guard lock(m_mutex);
        return static_cast<std::uint32_t>(m_sessions.size() + m_detached.size());
    }

    [[nodiscard]] std::uint32_t consumerCount() const {
        std::lock_guard lock(m_mutex);
        std::size_t     total = 0;
        for (const auto& entry : m_sessions) total += entry.second->consumerCount();
        for (const auto& session : m_detached) total += session->consumerCount();
        return static_cast<std::uint32_t>(total);
    }

private:
    mutable std::mutex                                         m_mutex;
    std::map<std::string, std::shared_ptr<SharedVideoSession>> m_sessions;
    /// Consumers split off a shared session. Held so the counts describe every
    /// decoder the registry is responsible for, not only the shareable ones.
    std::vector<std::shared_ptr<SharedVideoSession>>           m_detached;
    std::atomic<std::uint64_t>                                 m_next_consumer_id { 0 };
};

SharedVideoSourceHandle::~SharedVideoSourceHandle() {
    SharedVideoRegistry::Instance().release(session(), m_consumer_id);
    std::lock_guard lock(m_mutex);
    ReleaseAppleVideoFrame(&m_held);
    m_has_held = false;
}

bool SharedVideoSourceHandle::syncPlayback(const VideoPlaybackState& state, std::string* error) {
    auto current = session();
    if (! current) return false;
    if (! current->accepts(m_consumer_id, state)) {
        // This consumer wants a timeline the shared session is not running.
        // Give it its own decoder rather than dragging everyone onto one rate.
        if (auto detached = SharedVideoRegistry::Instance().detach(current, m_consumer_id)) {
            std::lock_guard lock(m_mutex);
            m_session = detached;
            current   = detached;
        }
    }
    {
        std::lock_guard lock(m_mutex);
        m_paused = state.paused;
    }
    return current->syncPlayback(m_consumer_id, state, error);
}

bool SharedVideoSourceHandle::refreshFrame(std::string* error) {
    std::shared_ptr<SharedVideoSession> current;
    bool                                paused = false;
    {
        std::lock_guard lock(m_mutex);
        current = m_session;
        paused  = m_paused;
    }
    if (! current) return false;

    // A paused surface keeps showing the frame it already holds. Advancing it
    // here would make one display's pause depend on another display still
    // running, which is exactly the coupling per-surface state must not have.
    if (paused) {
        std::lock_guard lock(m_mutex);
        return m_has_held;
    }

    if (! current->refreshFrame(error)) return false;

    VideoTextureFrame retained {};
    if (! current->source().retainCurrentFrame(&retained)) return false;
    std::lock_guard lock(m_mutex);
    ReleaseAppleVideoFrame(&m_held);
    m_held     = retained;
    m_has_held = true;
    return true;
}

} // namespace

void SetSharedVideoDecodeEnabled(bool enabled) {
    g_shared_decode_enabled.store(enabled, std::memory_order_relaxed);
}

bool SharedVideoDecodeEnabled() {
    return g_shared_decode_enabled.load(std::memory_order_relaxed);
}

std::uint32_t SharedVideoDecodeSessionCount() {
    return SharedVideoRegistry::Instance().sessionCount();
}

std::uint32_t SharedVideoDecodeConsumerCount() {
    return SharedVideoRegistry::Instance().consumerCount();
}

std::shared_ptr<VideoTextureSource> AcquireVideoTextureSource(const Image& image,
                                                              std::string* error) {
    return SharedVideoRegistry::Instance().acquire(image, error);
}

void ReleaseIdleVideoSessions() { SharedVideoRegistry::Instance().releaseIdle(); }

} // namespace video
} // namespace wallpaper
