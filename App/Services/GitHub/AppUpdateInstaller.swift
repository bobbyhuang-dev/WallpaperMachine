import AppKit
import Foundation

protocol AppUpdateInstalling {
    var canInstallInPlace: Bool { get }
    func prepareInstallation(archive: URL) throws -> URL
    func install(extractedApp: URL, replacing destination: URL) throws
}

struct AppUpdateInstaller: AppUpdateInstalling {
    let currentAppURL: URL
    let fileManager: FileManager

    init(currentAppURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default) {
        self.currentAppURL = currentAppURL
        self.fileManager = fileManager
    }

    var canInstallInPlace: Bool {
        Self.isInstallableLocation(currentAppURL)
    }

    static func isInstallableLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let applications = "/Applications/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).standardizedFileURL.path + "/"
        return path.hasPrefix(applications) || path.hasPrefix(userApplications)
    }

    /// Copies the app out of the downloaded disk image into a private work directory and
    /// validates the copy. The image is mounted invisibly and read-only, and is always
    /// detached before this returns or throws.
    func prepareInstallation(archive: URL) throws -> URL {
        let work = fileManager.temporaryDirectory.appendingPathComponent("mwe-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let app = try Self.copyApplication(fromDiskImage: archive, into: work)
            try Self.validate(app)
            return app
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

    func install(extractedApp: URL, replacing destination: URL) throws {
        guard canInstallInPlace else {
            throw AppUpdateIssue(code: .permission, detail: String(localized: "The updater doesn't have permission to install this update."))
        }
        let script = fileManager.temporaryDirectory.appendingPathComponent("mwe-install-\(UUID().uuidString).sh")
        let contents = """
        #!/bin/bash
        set -euo pipefail
        pid="$1"
        src="$2"
        dst="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        sleep 0.4
        rm -rf "$dst"
        /usr/bin/ditto "$src" "$dst"
        /usr/bin/xattr -dr com.apple.quarantine "$dst" || true
        /usr/bin/open "$dst"
        rm -rf "$(dirname "$src")"
        rm -f "$0"
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), extractedApp.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func copyApplication(fromDiskImage image: URL, into work: URL) throws -> URL {
        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            throw verificationIssue
        }
        defer { detach(mountPoint) }
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, image.path])
        let source = try findApplication(in: mountPoint)
        let copy = work.appendingPathComponent(AppUpdateConfiguration.applicationName, isDirectory: true)
        try run("/usr/bin/ditto", ["--noqtn", source.path, copy.path])
        return copy
    }

    /// Detaches only a mounted volume root, so a failed attach never hands `hdiutil` the
    /// path of a plain directory on the volume that holds the work directory.
    static func detach(_ mountPoint: URL) {
        guard isVolumeRoot(mountPoint) else { return }
        if (try? run("/usr/bin/hdiutil", ["detach", mountPoint.path])) == nil {
            try? run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
        }
    }

    private static func isVolumeRoot(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return (try? fresh.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw verificationIssue
        }
        guard process.terminationStatus == 0 else { throw verificationIssue }
    }

    /// Finds the single app in `root` without following symbolic links, so the disk
    /// image's `Applications` link is never traversed and a linked app never counts.
    static func findApplication(in root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw verificationIssue
        }
        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == AppUpdateConfiguration.applicationName {
                found.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        guard found.count == 1 else {
            throw verificationIssue
        }
        return found[0]
    }

    private static var verificationIssue: AppUpdateIssue {
        AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
    }

    static func validate(_ app: URL) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let values = NSDictionary(contentsOf: info) as? [String: Any],
              let identifier = values["CFBundleIdentifier"] as? String,
              identifier == AppUpdateConfiguration.bundleIdentifier
        else {
            throw AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
        }
        let executable = app.appendingPathComponent("Contents/MacOS/WallpaperMachine")
        guard FileManager.default.isReadableFile(atPath: executable.path) else {
            throw AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
        }
    }
}
