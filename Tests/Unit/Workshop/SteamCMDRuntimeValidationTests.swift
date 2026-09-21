import Darwin
import XCTest

@testable import WallpaperMachine

/// `SteamCMDRuntimeService` rejects shells and malformed Mach-O without touching the source.
@MainActor
final class SteamCMDRuntimeValidationTests: DownloaderTestCase {
  func testDefaultRuntimeRejectsShellWithoutExecutingOrChangingIt() throws {
    let root = try makeRuntime("printf unexpected > ../executed")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("runtime/steamcmd")
    let original = try Data(contentsOf: executable)
    XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable))
    XCTAssertEqual(try Data(contentsOf: executable), original)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
  }

  func testMalformedMachOLoadCommandsAreRejectedWithoutModifyingSource() throws {
    let root = try makeRuntime("exit 0")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("runtime/steamcmd")
    // A 64-bit executable declares a load-command table that exceeds the actual file.
    var malformed = Data()
    for word in [UInt32(0xfeed_facf), 0x0100_0007, 3, 2, 1, 4096, 0, 0] {
      var littleEndian = word.littleEndian
      withUnsafeBytes(of: &littleEndian) { malformed.append(contentsOf: $0) }
    }
    try malformed.write(to: executable)
    XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable)) { error in
      XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
    }
    XCTAssertEqual(try Data(contentsOf: executable), malformed)
  }

  func testFatBinaryRepeatingOneCPUTypeIsRejectedWithoutModifyingSource() throws {
    let root = try makeRuntime("exit 0")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("runtime/steamcmd")
    // Two x86_64 slices differing only by subtype: a CPU-keyed selection resolves one and
    // would leave the other unvalidated and unverified by codesign --arch.
    let slice = fixtureMachO(fileType: 2)
    var fat = Data()
    func append(_ values: [UInt32]) {
      for value in values {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { fat.append(contentsOf: $0) }
      }
    }
    let first = 4096, second = 8192
    append([0xcafebabe, 2])
    append([0x01000007, 3, UInt32(first), UInt32(slice.count), 12])
    append([0x01000007, 8, UInt32(second), UInt32(slice.count), 12])
    fat.append(Data(repeating: 0, count: first - fat.count))
    fat.append(slice)
    fat.append(Data(repeating: 0, count: second - fat.count))
    fat.append(slice)
    try fat.write(to: executable)
    XCTAssertThrowsError(try SteamCMDRuntimeService().resolve(executable: executable)) { error in
      XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
    }
    XCTAssertEqual(try Data(contentsOf: executable), fat)
  }

  func testDefaultProviderPreservesContainedFrameworkLinksAcrossPrivateVarAliases() async throws {
    let files = FileManager.default
    let directory = try makeMachOFrameworkRuntime()
    defer { try? files.removeItem(at: directory) }
    let root = directory.appendingPathComponent("MacOS", isDirectory: true)
    let framework = root.appendingPathComponent("Frameworks/Breakpad.framework", isDirectory: true)
    let aliasPath =
      root.path.hasPrefix("/private/var/")
      ? String(root.path.dropFirst("/private".count)) : root.path
    let privatePath = aliasPath.hasPrefix("/var/") ? "/private" + aliasPath : aliasPath
    let service = SteamCMDRuntimeService(processRunner: FixtureSystemAssessment())
    let alias = URL(fileURLWithPath: aliasPath, isDirectory: true)
    let physical = URL(fileURLWithPath: privatePath, isDirectory: true)
    try await service.validateBootstrap(at: physical)
    try await service.validate(at: alias)
    XCTAssertEqual(
      try service.resolve(executable: alias.appendingPathComponent("steamcmd")),
      try service.resolve(executable: physical.appendingPathComponent("steamcmd")))
    let staging = directory.appendingPathComponent("private-copy", isDirectory: true)
    let prepared = try await service.prepare(
      executable: physical.appendingPathComponent("steamcmd"), staging: staging)
    XCTAssertEqual(
      try Data(contentsOf: prepared), try Data(contentsOf: root.appendingPathComponent("steamcmd")))
    XCTAssertEqual(
      try files.destinationOfSymbolicLink(
        atPath: staging.appendingPathComponent("Frameworks/Breakpad.framework/Resources").path),
      "Versions/Current/Resources")
    XCTAssertEqual(
      try String(
        contentsOf: staging.appendingPathComponent(
          "Frameworks/Breakpad.framework/Resources/Info.txt"), encoding: .utf8),
      "sealed-resource-fixture")

    let outside = directory.appendingPathComponent("outside", isDirectory: true)
    try files.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("preserved".utf8).write(to: outside.appendingPathComponent("sentinel"))
    try files.removeItem(at: framework.appendingPathComponent("Resources"))
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Resources").path,
      withDestinationPath: "../../../outside")
    do {
      try await service.validate(at: physical)
      XCTFail("A framework link escaping its container must be rejected")
    } catch {
      XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
    }
    XCTAssertEqual(
      try String(contentsOf: outside.appendingPathComponent("sentinel"), encoding: .utf8),
      "preserved")
  }

  func testNestedHelperRetainsExecutableContextThroughDylibAndRPathChains() async throws {
    let files = FileManager.default
    let directory = try makeMachOFrameworkRuntime()
    defer { try? files.removeItem(at: directory) }
    let root = directory.appendingPathComponent("MacOS", isDirectory: true)
    let version = root.appendingPathComponent(
      "Frameworks/Breakpad.framework/Versions/A", isDirectory: true)
    let helper = version.appendingPathComponent("Helpers/report_sender")
    try files.createDirectory(
      at: helper.deletingLastPathComponent(), withIntermediateDirectories: false)
    let images = [
      (
        helper,
        fixtureMachO(
          fileType: 2, dependency: "@executable_path/../Resources/breakpadUtilities.dylib",
          rpaths: ["@executable_path/../Resources"])
      ),
      (
        version.appendingPathComponent("Resources/breakpadUtilities.dylib"),
        fixtureMachO(fileType: 6, dependency: "@rpath/helperSupport.dylib")
      ),
      (
        version.appendingPathComponent("Resources/helperSupport.dylib"),
        fixtureMachO(fileType: 6, dependency: "@executable_path/../Resources/last.dylib")
      ),
      (version.appendingPathComponent("Resources/last.dylib"), fixtureMachO(fileType: 6)),
    ]
    for (url, contents) in images { try contents.write(to: url) }
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let service = SteamCMDRuntimeService(processRunner: FixtureSystemAssessment())
    let staging = directory.appendingPathComponent("private-copy", isDirectory: true)
    _ = try await service.prepare(
      executable: root.appendingPathComponent("steamcmd"), staging: staging)
    for (url, contents) in images {
      let relative = String(url.path.dropFirst(root.path.count + 1))
      XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent(relative)), contents)
    }

    let outside = directory.appendingPathComponent("outside.dylib")
    let sentinel = fixtureMachO(fileType: 6)
    try sentinel.write(to: outside)
    try fixtureMachO(fileType: 6, dependency: "@executable_path/../../../../../../outside.dylib")
      .write(to: version.appendingPathComponent("Resources/last.dylib"))
    do {
      try await service.validate(at: root)
      XCTFail("Nested executable context must not permit escaping the runtime")
    } catch {
      XCTAssertEqual((error as? SteamCMDSetupIssue)?.kind, .incompleteRuntime)
    }
    XCTAssertEqual(try Data(contentsOf: outside), sentinel)
  }

  private func makeMachOFrameworkRuntime() throws -> URL {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(
      "mwe-framework-links-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("MacOS", isDirectory: true)
    let framework = root.appendingPathComponent("Frameworks/Breakpad.framework", isDirectory: true)
    let version = framework.appendingPathComponent("Versions/A", isDirectory: true)
    try files.createDirectory(
      at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try Data("sealed-resource-fixture".utf8).write(
      to: version.appendingPathComponent("Resources/Info.txt"))
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Resources").path,
      withDestinationPath: "Versions/Current/Resources")
    try files.createSymbolicLink(
      atPath: framework.appendingPathComponent("Breakpad").path,
      withDestinationPath: "Versions/Current/Breakpad")
    for (path, contents) in [
      (root.appendingPathComponent("steamcmd"), fixtureMachO(fileType: 2)),
      (
        root.appendingPathComponent("steamconsole.dylib"),
        fixtureMachO(fileType: 6, dependency: "@loader_path/crashhandler.dylib")
      ),
      (
        root.appendingPathComponent("crashhandler.dylib"),
        fixtureMachO(fileType: 6, dependency: "@loader_path/Breakpad.framework/Versions/A/Breakpad")
      ),
      (version.appendingPathComponent("Breakpad"), fixtureMachO(fileType: 6)),
    ] {
      try contents.write(to: path)
      try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: root.appendingPathComponent("steamcmd.sh"))
    return directory
  }

  private func fixtureMachO(fileType: UInt32, dependency: String? = nil, rpaths: [String] = [])
    -> Data
  {
    func words(_ values: [UInt32]) -> Data {
      var result = Data()
      for value in values {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
      }
      return result
    }
    var commands = Data()
    let entries = dependency.map { [(UInt32(0xc), $0)] } ?? []
    for (command, path) in entries + rpaths.map({ (UInt32(0x8000_001c), $0) }) {
      let name = Data((path + "\0").utf8)
      let header = command == 0xc ? 24 : 12
      let length = (header + name.count + 3) & ~3
      commands.append(words([command, UInt32(length), UInt32(header)]))
      if command == 0xc { commands.append(words([0, 0, 0])) }
      commands.append(name)
      commands.append(Data(repeating: 0, count: length - header - name.count))
    }
    return words([
      0xfeed_facf, 0x0100_0007, 3, fileType, UInt32(entries.count + rpaths.count),
      UInt32(commands.count), 0, 0,
    ]) + commands
  }
}
