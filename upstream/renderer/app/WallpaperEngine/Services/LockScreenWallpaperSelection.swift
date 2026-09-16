import AppKit
import Darwin

struct LockScreenWallpaperFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Deliberately edits only explicit physical-display overrides. Global defaults and
/// other displays belong to the user, even when they currently show our wallpaper.
@MainActor
final class LockScreenWallpaperSelection {
  private struct Entry: Codable {
    var path: [String]
    var original: Data
    var created: Bool
    var observeOnly: Bool? = nil
  }

  private static var lastReloadSignal: Date?

  private let storeURL: URL
  private let journalURL: URL
  private let reload: @MainActor () throws -> Void
  private var entries: [Entry] = []
  private var restartPending = false

  convenience init(folder: URL) {
    self.init(
      storeURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/com.apple.wallpaper/Store/Index.plist"),
      journalURL: folder.appendingPathComponent("native-selection.plist"),
      reload: { try Self.reloadWallpaperAgent() })
  }

  init(storeURL: URL, journalURL: URL, reload: @escaping @MainActor () throws -> Void) {
    self.storeURL = storeURL
    self.journalURL = journalURL
    self.reload = reload
  }

  func recover() throws {
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
    entries = try PropertyListDecoder().decode([Entry].self, from: Data(contentsOf: journalURL))
    // A crash may occur after the store write but before its service reload.
    restartPending = true
    try synchronize(displays: [])
  }

  func checkCompatibility() throws {
    let root =
      try PropertyListSerialization.propertyList(from: Data(contentsOf: storeURL), format: nil)
      as? [String: Any]
    if let global = root?["AllSpacesAndDisplays"] as? [String: Any],
      global["Type"] as? String == "linked"
    {
      throw LockScreenWallpaperFailure(
        message:
          "A system-wide linked wallpaper currently overrides individual displays. Turn off that wallpaper app or its all-displays setting before enabling Animate Lock Screen; the existing global wallpaper was not changed."
      )
    }
  }

  func synchronize(displays: Set<String>, revision: String? = nil) throws {
    if displays.isEmpty && entries.isEmpty && !restartPending { return }
    let bytes = try Data(contentsOf: storeURL)
    guard
      var root = try PropertyListSerialization.propertyList(from: bytes, format: nil)
        as? [String: Any],
      root["Displays"] is [String: Any], root["Spaces"] is [String: Any]
    else {
      throw LockScreenWallpaperFailure(
        message:
          "This macOS wallpaper store format is unsupported. Native selection was not changed.")
    }
    var paths = displays.sorted().map { ["Displays", $0] }
    for (space, value) in (root["Spaces"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key })
    {
      guard let node = value as? [String: Any], node["Displays"] is [String: Any] else {
        throw LockScreenWallpaperFailure(
          message: "This macOS Space has an unsupported wallpaper configuration.")
      }
      paths += displays.sorted().map { ["Spaces", space, "Displays", $0] }
    }
    let desired = Set(paths)
    var retained: [Entry] = []
    var changed = false
    let selection = try Self.selection(revision: revision)
    for entry in entries {
      if entry.observeOnly == true && !displays.isEmpty {
        retained.append(entry)
        continue
      }
      guard var node = Self.node(root, path: entry.path) else {
        if desired.contains(entry.path) {
          throw LockScreenWallpaperFailure(
            message:
              "A native wallpaper override was removed outside MacWallpaperEngine. Disable Animate Lock Screen before enabling it again."
          )
        }
        continue
      }
      let desktopOwned = Self.owns(node["Desktop"])
      let idleOwned = Self.owns(node["Idle"])
      if desired.contains(entry.path) {
        guard desktopOwned && idleOwned else {
          throw LockScreenWallpaperFailure(
            message:
              "The system wallpaper was changed outside MacWallpaperEngine. Disable Animate Lock Screen before enabling it again; external choices will be preserved."
          )
        }
        // Reloading the extension's manifest does not invalidate WallpaperAgent's
        // cached snapshots for inactive Spaces. Change the native choice identity
        // on publication, while retaining the first restoration journal entry.
        if revision != nil {
          var updated = false
          for key in ["Desktop", "Idle"] {
            let current = node[key] as? [String: Any]
            let content = current?["Content"] as? [String: Any]
            let choices = content?["Choices"] as? [[String: Any]]
            let expected = (selection["Content"] as? [String: Any])?["Choices"] as? [[String: Any]]
            if choices?.first?["Configuration"] as? Data != expected?.first?["Configuration"]
              as? Data
            {
              node[key] = selection
              updated = true
            }
          }
          if updated {
            Self.setNode(&root, path: entry.path, value: node)
            changed = true
          }
        }
        retained.append(entry)
        continue
      }
      guard desktopOwned || idleOwned else { continue }
      guard
        let original = try PropertyListSerialization.propertyList(from: entry.original, format: nil)
          as? [String: Any]
      else {
        throw LockScreenWallpaperFailure(
          message: "The native wallpaper restoration journal is invalid.")
      }
      if desktopOwned { node["Desktop"] = original["Desktop"] }
      if idleOwned { node["Idle"] = original["Idle"] }
      if desktopOwned && idleOwned && node["Type"] as? String == "individual" {
        node["Type"] = original["Type"]
      }
      let remove = entry.created && node.isEmpty
      Self.setNode(&root, path: entry.path, value: remove ? nil : node)
      changed = true
    }
    // macOS may copy explicit selections into fallback nodes on reload. Observe
    // every fallback before activation so those copies can be restored as well.
    let fallbackPaths =
      [["SystemDefault"]]
      + (root["Spaces"] as? [String: Any] ?? [:]).keys.sorted().map { ["Spaces", $0, "Default"] }
    for path in fallbackPaths
    where !displays.isEmpty && !retained.contains(where: { $0.path == path }) {
      let original = Self.node(root, path: path)
      retained.append(
        Entry(
          path: path,
          original: try Self.encode(
            Self.restorationOriginal(original ?? [:], path: path, root: root)),
          created: original == nil, observeOnly: true))
    }
    let restorationRoot = root
    for path in paths where !retained.contains(where: { $0.path == path }) {
      let existing = Self.node(root, path: path)
      var node = existing ?? [:]
      // An orphaned provider cannot be its own restoration target. Recover only
      // its fields from surviving native fallbacks; preserve external choices.
      let original = try Self.restorationOriginal(node, path: path, root: restorationRoot)
        .filter { ["Desktop", "Idle", "Type"].contains($0.key) }
      retained.append(
        Entry(path: path, original: try Self.encode(original), created: existing == nil))
      node["Desktop"] = selection
      node["Idle"] = selection
      node["Type"] = "individual"
      Self.setNode(&root, path: path, value: node)
      changed = true
    }
    if changed {
      // Journal the union first: recovery works both before and after the store commit.
      let recovery =
        entries + retained.filter { new in !entries.contains(where: { $0.path == new.path }) }
      try FileManager.default.createDirectory(
        at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListEncoder().encode(recovery).write(to: journalURL, options: .atomic)
      entries = recovery
      guard try Data(contentsOf: storeURL) == bytes else {
        throw LockScreenWallpaperFailure(
          message:
            "The system wallpaper changed during native selection. Please retry; no concurrent changes were overwritten."
        )
      }
      try Self.encode(root).write(to: storeURL, options: .atomic)
      restartPending = true
    }
    if restartPending {
      try reload()
      restartPending = false
    }
    entries = retained
    if entries.isEmpty {
      if FileManager.default.fileExists(atPath: journalURL.path) {
        try FileManager.default.removeItem(at: journalURL)
      }
    } else {
      try PropertyListEncoder().encode(entries).write(to: journalURL, options: .atomic)
    }
  }

  private static func restorationOriginal(
    _ node: [String: Any], path: [String], root: [String: Any]
  ) throws -> [String: Any] {
    var original = node
    var fallbackPaths: [[String]] = []
    if path.count == 4, path[0] == "Spaces" {
      fallbackPaths.append(["Displays", path[3]])
      fallbackPaths.append(["Spaces", path[1], "Default"])
    }
    fallbackPaths += [["SystemDefault"], ["AllSpacesAndDisplays"]]
    for key in ["Desktop", "Idle"] where owns(node[key]) {
      guard
        let replacement = fallbackPaths.lazy
          .filter({ $0 != path })
          .compactMap({ Self.node(root, path: $0)?[key] as? [String: Any] })
          .first(where: { value in
            guard !owns(value), let content = value["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], !choices.isEmpty
            else { return false }
            return choices.allSatisfy {
              guard let provider = $0["Provider"] as? String else { return false }
              return !provider.isEmpty && provider != LockScreenConfiguration.extensionIdentifier
            }
          })
      else {
        throw LockScreenWallpaperFailure(
          message:
            "A native wallpaper selection has no restoration journal or surviving system fallback. Choose a system wallpaper for this display before enabling Animate Lock Screen."
        )
      }
      original[key] = replacement
    }
    return original
  }

  private static func selection(revision: String?) throws -> [String: Any] {
    [
      "Content": [
        "Choices": [
          [
            "Provider": LockScreenConfiguration.extensionIdentifier,
            "Configuration": Data((revision.map { "current:" + $0 } ?? "current").utf8),
            "Files": [String](),
          ]
        ],
        "Shuffle": "$null", "EncodedOptionValues": try encode(["values": [String: Any]()]),
      ],
      "LastSet": Date(), "LastUse": Date(),
    ]
  }

  private static func owns(_ value: Any?) -> Bool {
    guard let selection = value as? [String: Any],
      let content = selection["Content"] as? [String: Any],
      let choices = content["Choices"] as? [[String: Any]], choices.count == 1
    else { return false }
    return choices[0]["Provider"] as? String == LockScreenConfiguration.extensionIdentifier
  }

  private static func encode(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
  }

  private static func node(_ root: [String: Any], path: [String]) -> [String: Any]? {
    var node = root
    for key in path {
      guard let child = node[key] as? [String: Any] else { return nil }
      node = child
    }
    return node
  }

  private static func setNode(_ root: inout [String: Any], path: [String], value: [String: Any]?) {
    guard let key = path.first else { return }
    if path.count == 1 {
      root[key] = value
      return
    }
    var child = root[key] as? [String: Any] ?? [:]
    setNode(&child, path: Array(path.dropFirst()), value: value)
    root[key] = child
  }

  /// Verify effective UID and the kernel-reported executable immediately before
  /// each signal. Never signal by name alone, restart Dock, or touch loginwindow.
  private static func reloadWallpaperAgent() throws {
    let expected = "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else {
      throw LockScreenWallpaperFailure(message: "Unable to enumerate the wallpaper service.")
    }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0, Int(count) <= pids.count else {
      throw LockScreenWallpaperFailure(message: "Unable to identify the wallpaper service safely.")
    }
    var found = false
    // PROC_PIDPATHINFO_MAXSIZE expands to 4*MAXPATHLEN and is not Swift-importable.
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(count)) where pid > 0 {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
        info.pbi_uid == getuid(), info.pbi_ruid == getuid()
      else { continue }
      let length = path.withUnsafeMutableBytes {
        proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
      }
      guard length > 0, String(cString: path) == expected else { continue }
      guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
        throw LockScreenWallpaperFailure(
          message:
            "macOS refused to reload the user-owned wallpaper service (errno \(errno)). The restoration journal was retained."
        )
      }
      found = true
    }
    if found {
      lastReloadSignal = Date()
      return
    }
    // We SIGTERMed the agent moments ago and launchd has not relaunched it yet.
    // The relaunch reads the store we just wrote, so no signal is needed.
    if let last = lastReloadSignal, Date().timeIntervalSince(last) < 10 { return }
    throw LockScreenWallpaperFailure(
      message:
        "No positively verified user-owned WallpaperAgent is running. Native selection could not be activated; its restoration journal was retained."
    )
  }
}
