#include "TexturePrefetch.hpp"

#include "Image.hpp"
#include "Interface/IImageParser.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using wallpaper::Image;
using wallpaper::ImageHeader;
using wallpaper::vulkan::TexturePrefetch;

namespace
{
using namespace std::chrono_literals;

/// Decodes by name on whichever thread asks. Decodes wait at a gate until the
/// test opens it, so what the prefetch admits can be observed mid-flight.
class GatedParser final : public wallpaper::IImageParser {
public:
    explicit GatedParser(bool open = false): m_open(open) {}

    std::shared_ptr<Image> Parse(const std::string& name) override {
        std::unique_lock lock(m_mutex);
        ++m_started[name];
        ++m_total_started;
        m_changed.notify_all();
        m_changed.wait(lock, [&] { return m_open; });
        if (name == failing) return nullptr;
        if (name == throwing) throw std::runtime_error("decoder threw");
        auto image = std::make_shared<Image>();
        image->key = name;
        m_decoded.push_back(image);
        return image;
    }

    ImageHeader ParseHeader(const std::string&) override { return {}; }

    void Open() {
        std::lock_guard lock(m_mutex);
        m_open = true;
        m_changed.notify_all();
    }

    bool WaitForStarted(std::size_t count) {
        std::unique_lock lock(m_mutex);
        return m_changed.wait_for(lock, 5s, [&] { return m_total_started >= count; });
    }

    std::size_t TotalStarted() {
        std::lock_guard lock(m_mutex);
        return m_total_started;
    }

    std::size_t Started(const std::string& name) {
        std::lock_guard lock(m_mutex);
        const auto found = m_started.find(name);
        return found == m_started.end() ? 0 : found->second;
    }

    bool AllDecodedImagesReleased() {
        std::lock_guard lock(m_mutex);
        return std::all_of(m_decoded.begin(), m_decoded.end(),
                           [](const auto& image) { return image.expired(); });
    }

    std::string failing;
    std::string throwing;

private:
    std::mutex                         m_mutex;
    std::condition_variable            m_changed;
    bool                               m_open;
    std::map<std::string, std::size_t> m_started;
    std::size_t                        m_total_started { 0 };
    std::vector<std::weak_ptr<Image>>  m_decoded;
};

/// Declared after the prefetch it guards: a test that stops early opens the
/// gate first, so teardown never waits on a decode held there.
struct OpenOnExit {
    GatedParser& parser;
    ~OpenOnExit() { parser.Open(); }
};

std::vector<TexturePrefetch::Request> Requests(const std::vector<std::string>& names,
                                               std::size_t bytes) {
    std::vector<TexturePrefetch::Request> requests;
    for (const auto& name : names) requests.push_back({ .name = name, .estimated_bytes = bytes });
    return requests;
}

/// Long enough for an idle worker to start any decode it is allowed to.
void LetWorkersRun() { std::this_thread::sleep_for(100ms); }

} // namespace

TEST(TexturePrefetch, HandsEachImageOverOnceUnderItsOwnName) {
    GatedParser parser(true);
    const std::vector<std::string> names { "a", "b", "c", "d", "e" };
    TexturePrefetch prefetch(parser, Requests(names, 10), 3, 1000);
    // Everything fits the budget. Waiting until all are admitted makes every
    // Take an answer from the prefetch rather than one left to the caller.
    ASSERT_TRUE(parser.WaitForStarted(names.size()));

    for (const auto& name : names) {
        const auto image = prefetch.Take(name);
        ASSERT_TRUE(image.has_value()) << name;
        ASSERT_NE(*image, nullptr) << name;
        EXPECT_EQ((*image)->key, name);
        EXPECT_EQ(parser.Started(name), 1u) << name;
    }
    EXPECT_FALSE(prefetch.Take("a").has_value()) << "a taken image is not handed over twice";
    EXPECT_FALSE(prefetch.Take("unscheduled").has_value());
}

TEST(TexturePrefetch, HoldsDecodingAndUntakenImagesWithinTheBudget) {
    GatedParser     parser;
    TexturePrefetch prefetch(parser, Requests({ "a", "b", "c", "d", "e" }, 10), 4, 30);
    OpenOnExit      open_on_exit { parser };

    ASSERT_TRUE(parser.WaitForStarted(3));
    LetWorkersRun();
    EXPECT_EQ(parser.TotalStarted(), 3u) << "a fourth decode would exceed the budget";

    parser.Open();
    LetWorkersRun();
    EXPECT_EQ(parser.TotalStarted(), 3u) << "decoded images count until they are taken";

    const auto first = prefetch.Take("a");
    ASSERT_TRUE(first.has_value() && *first != nullptr);
    ASSERT_TRUE(parser.WaitForStarted(4)) << "taking an image returns its share of the budget";
    const auto second = prefetch.Take("b");
    ASSERT_TRUE(second.has_value() && *second != nullptr);
    ASSERT_TRUE(parser.WaitForStarted(5));
    for (const std::string name : { "c", "d", "e" }) {
        const auto image = prefetch.Take(name);
        ASSERT_TRUE(image.has_value() && *image != nullptr) << name;
        EXPECT_EQ((*image)->key, name);
    }
}

TEST(TexturePrefetch, AdmitsAnImageLargerThanTheBudgetOnItsOwn) {
    GatedParser parser;
    std::vector<TexturePrefetch::Request> requests {
        { .name = "large", .estimated_bytes = 100 },
        { .name = "small", .estimated_bytes = 10 },
    };
    TexturePrefetch prefetch(parser, std::move(requests), 2, 30);
    OpenOnExit      open_on_exit { parser };

    ASSERT_TRUE(parser.WaitForStarted(1));
    LetWorkersRun();
    EXPECT_EQ(parser.Started("small"), 0u);

    parser.Open();
    const auto large = prefetch.Take("large");
    ASSERT_TRUE(large.has_value() && *large != nullptr);
    ASSERT_TRUE(parser.WaitForStarted(2));
    const auto small = prefetch.Take("small");
    ASSERT_TRUE(small.has_value() && *small != nullptr);
    EXPECT_EQ((*small)->key, "small");
}

TEST(TexturePrefetch, LeavesAnImageNotYetAdmittedToTheCallerWithoutWaiting) {
    GatedParser     parser;
    TexturePrefetch prefetch(parser, Requests({ "a", "b", "c", "d" }, 10), 2, 10);
    OpenOnExit      open_on_exit { parser };
    ASSERT_TRUE(parser.WaitForStarted(1));

    // "a" is still decoding and holds the whole budget, so "c" was never
    // admitted. The caller gets it back at once rather than waiting on "a".
    EXPECT_FALSE(prefetch.Take("c").has_value());

    parser.Open();
    ASSERT_TRUE(parser.WaitForStarted(2)) << "admission resumes past the skip";
    const auto after = prefetch.Take("d");
    ASSERT_TRUE(after.has_value() && *after != nullptr);
    EXPECT_EQ((*after)->key, "d");
    EXPECT_EQ(parser.Started("b"), 0u) << "a skipped image is not decoded later";
    EXPECT_EQ(parser.Started("c"), 0u);
    EXPECT_FALSE(prefetch.Take("a").has_value()) << "skipped images are given up";
    EXPECT_FALSE(prefetch.Take("b").has_value());
}

TEST(TexturePrefetch, ReportsAFailedDecodeButLeavesAThrowingOneToTheCaller) {
    GatedParser parser(true);
    parser.failing  = "corrupt";
    parser.throwing = "unlucky";
    TexturePrefetch prefetch(parser, Requests({ "corrupt", "unlucky", "fine" }, 10), 2, 1000);
    ASSERT_TRUE(parser.WaitForStarted(3));

    const auto corrupt = prefetch.Take("corrupt");
    ASSERT_TRUE(corrupt.has_value()) << "a decode that failed is an answer, not a retry";
    EXPECT_EQ(*corrupt, nullptr);
    EXPECT_FALSE(prefetch.Take("unlucky").has_value());
    const auto fine = prefetch.Take("fine");
    ASSERT_TRUE(fine.has_value() && *fine != nullptr);
}

TEST(TexturePrefetch, WithoutWorkersEveryImageIsLeftToTheCallerAtOnce) {
    // What a prefetch whose threads all failed to start looks like: nothing is
    // ever admitted, so waiting on an image would hang preparation.
    GatedParser     parser(true);
    TexturePrefetch prefetch(parser, Requests({ "a", "b" }, 10), 0, 1000);

    EXPECT_FALSE(prefetch.Take("a").has_value());
    EXPECT_FALSE(prefetch.Take("b").has_value());
    EXPECT_EQ(parser.TotalStarted(), 0u);
}

TEST(TexturePrefetch, TeardownWaitsForRunningDecodesAndReleasesEveryImage) {
    GatedParser parser;
    std::thread opener;
    {
        TexturePrefetch prefetch(parser, Requests({ "a", "b", "c", "d" }, 10), 2, 1000);
        EXPECT_TRUE(parser.WaitForStarted(2));
        // Opens only after teardown has begun waiting on the held decodes.
        opener = std::thread([&parser] {
            std::this_thread::sleep_for(50ms);
            parser.Open();
        });
    }
    opener.join();
    EXPECT_TRUE(parser.AllDecodedImagesReleased());
}
