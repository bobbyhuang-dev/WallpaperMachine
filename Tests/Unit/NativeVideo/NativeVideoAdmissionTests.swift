import AVFoundation
import CoreMedia
import XCTest

@testable import MacWallpaperEngine

/// The native backend's admission rule, exercised against real files.
///
/// Every clip here is written by `SyntheticVideoFixture` and then read back
/// through `NativeVideoAdmission.probe`, so what is asserted is what
/// AVFoundation reports about a finished file — not the rate the generator was
/// asked for. Each case logs the API's own answer next to the verdict, because
/// the verdict alone does not say which field produced it.
///
/// No window, no player, no desktop: this is metadata and arithmetic.
final class NativeVideoAdmissionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-video-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func probeFixture(
        _ request: SyntheticVideoFixture.Request, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> NativeVideoTrackProbe {
        let url = try await SyntheticVideoFixture.write(request, into: directory)
        switch await NativeVideoAdmission.probe(url: url) {
        case let .probed(probe):
            // The record the plan asks for: what the API returned, verbatim.
            print("[admission] \(request.name): \(probe.apiDescription)")
            return probe
        case let .refused(refusal):
            XCTFail("\(request.name) should be probeable: \(refusal.reason)", file: file, line: line)
            throw XCTSkip("probe failed")
        }
    }

    private func report(
        _ name: String, _ probe: NativeVideoTrackProbe, target: UInt32,
        _ decision: NativeVideoRefusal?
    ) {
        let verdict = decision.map { "REFUSED: \($0.reason)" } ?? "ACCEPTED"
        print("[admission] \(name) target=\(target) -> \(verdict)")
    }

    // MARK: - Integer rates

    func testWholeNumberRatesAreAcceptedAtOrAboveTheirOwnRate() async throws {
        for rate in [24, 25, 30, 60] as [CMTimeValue] {
            let probe = try await probeFixture(
                .constantRate(
                    name: "cfr-\(rate)", numerator: rate, denominator: 1, frames: 8))
            XCTAssertEqual(
                Double(probe.nominalFrameRate), Double(rate), accuracy: 0.05,
                "the file should read back at the rate it was written at")

            let atOwnRate = NativeVideoAdmission.decide(probe: probe, targetFps: UInt32(rate))
            report("cfr-\(rate)", probe, target: UInt32(rate), atOwnRate)
            XCTAssertNil(atOwnRate, "a clip at exactly the target rate is honourable")

            let above = NativeVideoAdmission.decide(probe: probe, targetFps: UInt32(rate) + 30)
            XCTAssertNil(above, "a target above the clip's rate is honourable")
        }
    }

    func testAClipFasterThanTheTargetIsRefused() async throws {
        let probe = try await probeFixture(
            .constantRate(name: "cfr-60-refused", numerator: 60, denominator: 1, frames: 8))
        let decision = NativeVideoAdmission.decide(probe: probe, targetFps: 30)
        report("cfr-60", probe, target: 30, decision)
        guard case let .targetFrameRateBelowContent(target, bound, _) = decision else {
            return XCTFail("a 60 fps clip cannot be honoured at 30: \(String(describing: decision))")
        }
        XCTAssertEqual(target, 30)
        XCTAssertEqual(bound, 60, accuracy: 0.05)
    }

    // MARK: - NTSC rates

    func testNtscRatesAreAcceptedAgainstTheNextWholeTarget() async throws {
        // 30000/1001 is 29.97, which is below 30. This needs no tolerance at
        // all, and the round-3 code's blanket one-frame slack was hiding real
        // over-limit content rather than solving this.
        let cases: [(String, CMTimeValue, UInt32, Double)] = [
            ("ntsc-24", 24000, 24, 23.976),
            ("ntsc-30", 30000, 30, 29.97),
            ("ntsc-60", 60000, 60, 59.94),
        ]
        for (name, numerator, target, expected) in cases {
            let probe = try await probeFixture(
                .constantRate(name: name, numerator: numerator, denominator: 1001, frames: 8))
            XCTAssertEqual(Double(probe.nominalFrameRate), expected, accuracy: 0.05)
            let decision = NativeVideoAdmission.decide(probe: probe, targetFps: target)
            report(name, probe, target: target, decision)
            XCTAssertNil(decision, "\(expected) fps is below \(target) and must be accepted")
        }
    }

    func testARateLessThanOneFrameAboveTheTargetIsStillRefused() async throws {
        // 29.97 against a target of 29 is over the limit by less than one
        // frame per second. The previous rule accepted it, which is exactly
        // the silent quality change the target rate exists to prevent.
        let probe = try await probeFixture(
            .constantRate(name: "ntsc-30-vs-29", numerator: 30000, denominator: 1001, frames: 8))
        let decision = NativeVideoAdmission.decide(probe: probe, targetFps: 29)
        report("ntsc-30-vs-29", probe, target: 29, decision)
        guard case let .targetFrameRateBelowContent(_, bound, _) = decision else {
            return XCTFail("29.97 exceeds a target of 29: \(String(describing: decision))")
        }
        XCTAssertEqual(bound, 29.97, accuracy: 0.05)

        let sixty = try await probeFixture(
            .constantRate(name: "cfr-60-vs-59", numerator: 60, denominator: 1, frames: 8))
        let atFiftyNine = NativeVideoAdmission.decide(probe: sixty, targetFps: 59)
        report("cfr-60-vs-59", sixty, target: 59, atFiftyNine)
        XCTAssertNotNil(atFiftyNine, "60 fps exceeds a target of 59 by less than one frame")
    }

    // MARK: - Variable frame rate

    func testAVariableRateClipIsJudgedByItsFastestInterval() async throws {
        // Average 15, burst at 60. A rule that trusted the average would play
        // the burst at four times the user's target.
        let probe = try await probeFixture(
            .variableRate(
                name: "vfr-15-60", slowRate: 15, fastRate: 60, slowFrames: 6, fastFrames: 6))
        let atThirty = NativeVideoAdmission.decide(probe: probe, targetFps: 30)
        report("vfr-15-60", probe, target: 30, atThirty)
        let bound = NativeVideoAdmission.presentationRateBound(probe)
        XCTAssertNotNil(bound, "a VFR clip still has a fastest interval")
        if let bound, bound.rate > 30 {
            XCTAssertNotNil(
                atThirty, "a burst faster than the target must send the clip to the engine")
        } else {
            XCTAssertNil(atThirty, "nothing in the metadata exceeds the target")
        }
        // Whatever the container reported, the clip is honourable at a target
        // at or above its fastest interval.
        if let bound {
            XCTAssertNil(
                NativeVideoAdmission.decide(
                    probe: probe, targetFps: UInt32(bound.rate.rounded(.up)) + 1))
        }
    }

    // MARK: - Assets that cannot be judged

    func testACorruptFileIsRefusedAsUnplayable() async throws {
        let url = try SyntheticVideoFixture.writeCorrupt(name: "corrupt", into: directory)
        let outcome = await NativeVideoAdmission.probe(url: url)
        guard case let .refused(refusal) = outcome else {
            return XCTFail("a file that is not a movie must not be probed as one")
        }
        print("[admission] corrupt -> REFUSED: \(refusal.reason)")
        guard case .notPlayable = refusal else {
            return XCTFail("expected notPlayable, got \(refusal)")
        }
    }

    func testAMissingFileIsRefusedRatherThanCrashing() async {
        let url = directory.appendingPathComponent("absent.mov")
        let decision = await NativeVideoAdmission.evaluate(url: url, targetFps: 60)
        print("[admission] absent -> \(decision?.reason ?? "ACCEPTED")")
        XCTAssertNotNil(decision)
    }

    // MARK: - Metadata shapes no encoder here produces

    func testAPositiveNominalRateAloneNeverAdmitsAClip() {
        // The nominal rate is an *average*. A 24 fps average is equally
        // consistent with a constant 24 fps clip and with one that sits at 12
        // and bursts to 60, and the burst is what would be presented over the
        // target. Admitting on the average alone is the same fault as round
        // 3's, reached through a different field, so every unusable minimum
        // has to be refused even when the average looks comfortable.
        for minimum in [CMTime.invalid, .indefinite, .zero, CMTime(value: 0, timescale: 600)] {
            let probe = NativeVideoTrackProbe(
                isPlayable: true, hasVideoTrack: true, nominalFrameRate: 24,
                minFrameDuration: minimum)
            XCTAssertNil(
                NativeVideoAdmission.presentationRateBound(probe),
                "an average cannot bound a maximum: \(probe.apiDescription)")
            guard case .frameRateNotDeterminable = NativeVideoAdmission.decide(
                probe: probe, targetFps: 30)
            else {
                return XCTFail(
                    "24 fps average with \(probe.apiDescription) must go to the scene engine")
            }
        }
    }

    func testAUsableMinimumIsWhatMakesAClipAdmissible() {
        // The positive control for the case above: the same nominal rate, now
        // with a shortest frame duration that actually bounds the track.
        let bounded = NativeVideoTrackProbe(
            isPlayable: true, hasVideoTrack: true, nominalFrameRate: 24,
            minFrameDuration: CMTime(value: 1, timescale: 24))
        XCTAssertEqual(NativeVideoAdmission.presentationRateBound(bounded)?.rate ?? 0, 24,
            accuracy: 0.001)
        XCTAssertNil(NativeVideoAdmission.decide(probe: bounded, targetFps: 30))
    }

    func testUnusableFrameDurationsAreNotDividedThrough() {
        for duration in [CMTime.invalid, .indefinite, .zero, CMTime(value: 0, timescale: 600)] {
            XCTAssertFalse(
                NativeVideoAdmission.isUsable(duration),
                "\(duration) is not a duration and must not become a frame rate")
        }
        let unknown = NativeVideoTrackProbe(
            isPlayable: true, hasVideoTrack: true, nominalFrameRate: 0,
            minFrameDuration: .invalid)
        let decision = NativeVideoAdmission.decide(probe: unknown, targetFps: 60)
        guard case .frameRateNotDeterminable = decision else {
            return XCTFail("an unbounded rate is a refusal, not an acceptance: \(String(describing: decision))")
        }
    }

    func testInterlacedContentGoesToTheSceneEngine() {
        // `nominalFrameRate` is the field rate for some interlaced encodes and
        // the frame rate for others. Guessing would be a silent rate change,
        // so the backend that paces its own frames takes it.
        let interlaced = NativeVideoTrackProbe(
            isPlayable: true, hasVideoTrack: true, nominalFrameRate: 29.97,
            minFrameDuration: CMTime(value: 1001, timescale: 30000), fieldCount: 2)
        guard case .frameRateNotDeterminable = NativeVideoAdmission.decide(
            probe: interlaced, targetFps: 60)
        else {
            return XCTFail("interlaced content must not be admitted on an ambiguous rate")
        }
        var progressive = interlaced
        progressive.fieldCount = 1
        XCTAssertNil(
            NativeVideoAdmission.decide(probe: progressive, targetFps: 60),
            "the same rates are fine once the track says one field per frame")
    }

    func testAnAverageRateBelowTheTargetDoesNotExcuseAFasterInterval() {
        // The inconsistent-metadata case: the track claims 30 on average but
        // declares a shortest frame of 1/60 s.
        let inconsistent = NativeVideoTrackProbe(
            isPlayable: true, hasVideoTrack: true, nominalFrameRate: 30,
            minFrameDuration: CMTime(value: 1, timescale: 60))
        guard case let .targetFrameRateBelowContent(_, bound, source) = NativeVideoAdmission
            .decide(probe: inconsistent, targetFps: 30)
        else {
            return XCTFail("the tighter of the two fields has to win")
        }
        XCTAssertEqual(bound, 60, accuracy: 0.001)
        XCTAssertEqual(source, "minFrameDuration")
    }

    func testAZeroTargetIsNotTreatedAsUnlimited() {
        let probe = NativeVideoTrackProbe(
            isPlayable: true, hasVideoTrack: true, nominalFrameRate: 30,
            minFrameDuration: CMTime(value: 1, timescale: 30))
        guard case .frameRateNotDeterminable = NativeVideoAdmission.decide(
            probe: probe, targetFps: 0)
        else {
            return XCTFail("a zero target must not divide through as an infinite budget")
        }
    }

    func testARealAudioOnlyFileIsRefusedForHavingNoVideoTrack() async throws {
        // Exercised against AVFoundation actually returning an empty video
        // track list, not against a probe asserting itself. Writing an LPCM
        // track is file I/O: it opens no audio device and plays nothing.
        let url = try await SyntheticVideoFixture.writeAudioOnly(
            name: "audio-only", into: directory)
        let outcome = await NativeVideoAdmission.probe(url: url)
        guard case let .refused(refusal) = outcome else {
            return XCTFail("a file with no video track must not be probed as one")
        }
        print("[admission] audio-only -> REFUSED: \(refusal.reason)")
        guard case let .notPlayable(detail) = refusal else {
            return XCTFail("expected notPlayable, got \(refusal)")
        }
        XCTAssertTrue(
            detail.contains("no video track"),
            "the reason must name the missing video track, got: \(detail)")
    }

    func testATrackWithoutVideoIsRefused() {
        let audioOnly = NativeVideoTrackProbe(
            isPlayable: true, hasVideoTrack: false, nominalFrameRate: 0,
            minFrameDuration: .invalid)
        guard case .notPlayable = NativeVideoAdmission.decide(probe: audioOnly, targetFps: 60)
        else {
            return XCTFail("a clip with no video track cannot be a wallpaper")
        }
    }
}
