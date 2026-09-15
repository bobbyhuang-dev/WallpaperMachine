import Darwin
import XCTest
@testable import MacWallpaperEngine

@MainActor
final class SteamCMDApprovalTests: XCTestCase {
    func testPolicyRejectionAndCandidatePreparationNeverCreateApproval() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        try fixture.attribute("com.apple.quarantine", value: "0081;fixture", at: fixture.executable)
        let service = fixture.service()
        await expect(.securityApprovalRequired) { try await service.validate(at: fixture.runtime) }
        _ = try await service.approvalCandidate(at: fixture.runtime, bootstrap: false)
        await expect(.securityApprovalRequired) { try await service.validate(at: fixture.runtime) }
        XCTAssertEqual(try fixture.attribute("com.apple.quarantine", at: fixture.executable), "0081;fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipts.path))
    }

    func testSystemAcceptanceNeverCreatesExplicitApproval() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        try await fixture.service(runner: ApprovalSystemRunner(assessmentStatus: 0)).validate(at: fixture.runtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipts.path))
        await expect(.securityApprovalRequired) { try await fixture.service().validate(at: fixture.runtime) }
    }

    func testSignedCommandLineToolDoesNotRequireExplicitApproval() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        try fixture.attribute("com.apple.quarantine", value: "0081;fixture", at: fixture.executable)
        let runner = ApprovalSystemRunner(
            assessmentOutput: "\(fixture.executable.path): rejected (the code is valid but does not seem to be an app)\n")
        try await fixture.service(runner: runner).validate(at: fixture.runtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipts.path))
        XCTAssertEqual(try fixture.attribute("com.apple.quarantine", at: fixture.executable), "0081;fixture")
    }

    func testBrokenBundleResourceSealValidatesWhileTheExecutableStaysPinnedToValve() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        // Valve's own updater installs a Breakpad.framework whose sealed Headers/Breakpad.h no longer
        // matches its CodeResources, so any bundle-wide resource check rejects a genuine installation.
        let sealed = ApprovalSystemRunner(assessmentStatus: 0, sealedResourcesModified: true)
        try await fixture.service(runner: sealed).validate(at: fixture.runtime)
        // Skipping resource seals is only safe while the executable this app spawns stays Valve's.
        let foreign = ApprovalSystemRunner(assessmentStatus: 0, satisfiesRequirement: false)
        await expect(.invalidSignature) { try await fixture.service(runner: foreign).validate(at: fixture.runtime) }
    }

    func testExplicitApprovalIsNarrowAndSurvivesRelaunchAndPrivateCopy() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let sentinel = fixture.directory.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: sentinel)
        let unrelated = fixture.runtime.appendingPathComponent("unrelated")
        try Data("not-a-runtime-file".utf8).write(to: unrelated)
        for url in [fixture.executable, fixture.resource, fixture.runtime, sentinel, unrelated] {
            try fixture.attribute("com.apple.quarantine", value: "0081;fixture", at: url)
        }
        try fixture.attribute("com.example.mwe.fixture", value: "preserved", at: fixture.executable)
        let runner = ApprovalSystemRunner()
        let service = fixture.service(runner: runner)
        let candidate = try await service.approvalCandidate(at: fixture.runtime, bootstrap: false)
        try await service.approve(candidate)
        for url in [fixture.executable, fixture.resource, fixture.runtime] {
            XCTAssertNil(try fixture.attribute("com.apple.quarantine", at: url))
        }
        for url in [sentinel, unrelated] {
            XCTAssertEqual(try fixture.attribute("com.apple.quarantine", at: url), "0081;fixture")
        }
        XCTAssertEqual(try fixture.attribute("com.example.mwe.fixture", at: fixture.executable), "preserved")
        let fresh = fixture.service(runner: runner)
        let previousAssessments = await runner.assessments
        try await fresh.validate(at: fixture.runtime)
        let currentAssessments = await runner.assessments
        XCTAssertEqual(currentAssessments, previousAssessments + 1)
        let privateCopy = fixture.directory.appendingPathComponent("private-copy")
        let executable = try await fresh.prepare(executable: fixture.executable, staging: privateCopy)
        XCTAssertEqual(executable, privateCopy.appendingPathComponent("steamcmd"))
        try await fresh.validate(at: privateCopy)
        let copied = try await fresh.approvalCandidate(at: privateCopy, bootstrap: false)
        XCTAssertEqual(copied.fingerprint, candidate.fingerprint)
        let record = fixture.receipts.appendingPathComponent(candidate.fingerprint)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testChangedImageRevokesApprovalAndStaleCandidateCannotClearQuarantine() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let candidate = try await service.approvalCandidate(at: fixture.runtime, bootstrap: false)
        try await service.approve(candidate)
        var changed = try Data(contentsOf: fixture.executable)
        changed.append(0x41)
        try changed.write(to: fixture.executable)
        try fixture.attribute("com.apple.quarantine", value: "0081;updated", at: fixture.executable)
        await expect(.securityApprovalRequired) { try await service.validate(at: fixture.runtime) }
        await expect(.fileSystem) { try await service.approve(candidate) }
        XCTAssertEqual(try fixture.attribute("com.apple.quarantine", at: fixture.executable), "0081;updated")
    }

    func testChangedSealedResourceRevokesApproval() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.approve(service.approvalCandidate(at: fixture.runtime, bootstrap: false))
        try Data("changed-resource".utf8).write(to: fixture.resource)
        await expect(.securityApprovalRequired) { try await service.validate(at: fixture.runtime) }
    }

    func testChangedContainedLinkTargetRevokesApproval() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.approve(service.approvalCandidate(at: fixture.runtime, bootstrap: false))
        let link = fixture.runtime.appendingPathComponent("Frameworks/Breakpad.framework/Breakpad")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Versions/A/Breakpad")
        await expect(.securityApprovalRequired) { try await service.validate(at: fixture.runtime) }
    }

    func testChangedModeRevokesApproval() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try await service.approve(service.approvalCandidate(at: fixture.runtime, bootstrap: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o744], ofItemAtPath: fixture.executable.path)
        await expect(.securityApprovalRequired) { try await service.validate(at: fixture.runtime) }
    }

    func testInvalidSignaturesCannotBeApprovedOrBypassedByExistingReceipt() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let candidate = try await service.approvalCandidate(at: fixture.runtime, bootstrap: false)
        try await service.approve(candidate)
        try fixture.attribute("com.apple.quarantine", value: "0081;fixture", at: fixture.executable)
        let rejected = fixture.service(runner: ApprovalSystemRunner(signatureStatus: 1))
        await expect(.invalidSignature) { try await rejected.validate(at: fixture.runtime) }
        await expect(.invalidSignature) { _ = try await rejected.approvalCandidate(at: fixture.runtime, bootstrap: false) }
        await expect(.invalidSignature) { try await rejected.approve(candidate) }
        XCTAssertEqual(try fixture.attribute("com.apple.quarantine", at: fixture.executable), "0081;fixture")
    }

    func testBootstrapApprovalDoesNotApproveUpdatedCompleteRuntime() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let console = fixture.runtime.appendingPathComponent("steamconsole.dylib")
        let bytes = try Data(contentsOf: console)
        try FileManager.default.removeItem(at: console)
        let service = fixture.service()
        let bootstrap = try await service.approvalCandidate(at: fixture.runtime, bootstrap: true)
        try await service.approve(bootstrap)
        try await service.validateBootstrap(at: fixture.runtime)
        try bytes.write(to: console)
        await expect(.securityApprovalRequired) { try await service.validate(at: fixture.runtime) }
    }

    func testReceiptSymlinksAndHardLinksCannotSupplyApproval() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let candidate = try await service.approvalCandidate(at: fixture.runtime, bootstrap: false)
        try await service.approve(candidate)
        let record = fixture.receipts.appendingPathComponent(candidate.fingerprint)
        let outside = fixture.directory.appendingPathComponent("outside-record")
        try FileManager.default.moveItem(at: record, to: outside)
        try FileManager.default.createSymbolicLink(atPath: record.path, withDestinationPath: outside.path)
        await expect(.fileSystem) { try await service.validate(at: fixture.runtime) }
        try FileManager.default.removeItem(at: record)
        try FileManager.default.linkItem(at: outside, to: record)
        await expect(.fileSystem) { try await service.validate(at: fixture.runtime) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "SteamCMD approval v1\n" + candidate.fingerprint + "\n")
    }

    func testSymlinkedReceiptDirectoryFailsBeforeChangingQuarantine() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let candidate = try await service.approvalCandidate(at: fixture.runtime, bootstrap: false)
        let outside = fixture.directory.appendingPathComponent("outside-receipts")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: fixture.receipts.path, withDestinationPath: outside.path)
        try fixture.attribute("com.apple.quarantine", value: "0081;fixture", at: fixture.executable)
        await expect(.fileSystem) { try await service.approve(candidate) }
        XCTAssertEqual(try fixture.attribute("com.apple.quarantine", at: fixture.executable), "0081;fixture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testAssessmentFailureCannotUseReceiptOrProduceApprovalCandidate() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let candidate = try await service.approvalCandidate(at: fixture.runtime, bootstrap: false)
        try await service.approve(candidate)
        let failing = fixture.service(runner: ApprovalSystemRunner(assessmentStatus: 1))
        await expect(.securityApprovalRequired) { try await failing.validate(at: fixture.runtime) }
        await expect(.securityApprovalRequired) { _ = try await failing.approvalCandidate(at: fixture.runtime, bootstrap: false) }
        await expect(.securityApprovalRequired) { try await failing.approve(candidate) }
    }

    private func expect(_ kind: SteamCMDSetupIssue.Kind, operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected rejection: \(kind)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, kind, file: file, line: line)
        }
    }
}

private struct ApprovalFixture {
    let directory: URL
    let runtime: URL
    let receipts: URL
    var executable: URL { runtime.appendingPathComponent("steamcmd") }
    var resource: URL { runtime.appendingPathComponent("Frameworks/Breakpad.framework/Versions/A/Resources/Info.txt") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-approval-\(UUID().uuidString)").resolvingSymlinksInPath()
        runtime = directory.appendingPathComponent("MacOS")
        receipts = directory.appendingPathComponent("Approvals")
        let framework = runtime.appendingPathComponent("Frameworks/Breakpad.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data("sealed-resource-fixture".utf8).write(to: resource)
        for (name, target) in [("Versions/Current", "A"), ("Breakpad", "Versions/Current/Breakpad"), ("Resources", "Versions/Current/Resources")] {
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent(name).path, withDestinationPath: target)
        }
        for (url, type) in [(executable, UInt32(2)), (runtime.appendingPathComponent("crashhandler.dylib"), UInt32(6)),
                            (runtime.appendingPathComponent("steamconsole.dylib"), UInt32(6)), (version.appendingPathComponent("Breakpad"), UInt32(6))] {
            var bytes = Data()
            for value: UInt32 in [0xfeedfacf, 0x01000007, 3, type, 0, 0, 0, 0] {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
            }
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runtime.appendingPathComponent("steamcmd.sh"))
    }

    func service(runner: ApprovalSystemRunner = ApprovalSystemRunner()) -> SteamCMDRuntimeService {
        SteamCMDRuntimeService(processRunner: runner, approvalDirectory: receipts)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func attribute(_ name: String, value: String, at url: URL) throws {
        let data = Data(value.utf8)
        let status = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func attribute(_ name: String, at url: URL) throws -> String? {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if count < 0, errno == ENOATTR { return nil }
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard actual == count else { throw POSIXError(.EIO) }
        return String(decoding: data, as: UTF8.self)
    }
}

private actor ApprovalSystemRunner: SteamCMDProcessRunning {
    let signatureStatus: Int32
    let assessmentStatus: Int32
    let assessmentOutput: String
    let sealedResourcesModified: Bool
    let satisfiesRequirement: Bool
    private(set) var assessments = 0
    init(signatureStatus: Int32 = 0, assessmentStatus: Int32 = 3, assessmentOutput: String = "",
         sealedResourcesModified: Bool = false, satisfiesRequirement: Bool = true) {
        self.signatureStatus = signatureStatus
        self.assessmentStatus = assessmentStatus
        self.assessmentOutput = assessmentOutput
        self.sealedResourcesModified = sealedResourcesModified
        self.satisfiesRequirement = satisfiesRequirement
    }

    func run(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
             onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        switch executable.path {
        case "/usr/bin/codesign":
            // codesign(1): resource seals are only read without --ignore-resources, and an
            // unsatisfied -R requirement exits 3 rather than reporting a broken signature.
            if sealedResourcesModified, !arguments.contains("--ignore-resources") { return 1 }
            if !satisfiesRequirement, arguments.contains(where: { $0.hasPrefix("-R=") }) { return 3 }
            return signatureStatus
        case "/usr/sbin/spctl":
            assessments += 1
            if !assessmentOutput.isEmpty { onOutput(Data(assessmentOutput.utf8)) }
            return assessmentStatus
        case "/usr/bin/arch": return 0
        default: throw WorkshopFailure(message: "Approval fixtures must never execute runtime code")
        }
    }
}
