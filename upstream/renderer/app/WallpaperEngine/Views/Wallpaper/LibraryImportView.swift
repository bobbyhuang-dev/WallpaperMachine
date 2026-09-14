import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryImportView: View {
    @Environment(BridgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [URL] = []
    @State private var duplicatePolicy: WallpaperImportService.DuplicatePolicy = .skip
    @State private var importTask: Task<Void, Never>?
    @State private var progress = "Preparing import…"
    @State private var report: WallpaperImportService.Report?
    @State private var errorMessage: String?
    private let service = WallpaperImportService()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import to MacWallpaperEngine").font(.title2.bold())
                    Text("Your originals stay exactly where they are.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Choose Wallpaper Engine project folders, a Steam library, or video files. Projects are copied into your local library only when their files are ready.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Web projects can be saved to your library, but this renderer cannot play them. For HTML with assets, import the complete project folder. Standalone images are not supported.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !sources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sources, id: \.path) { source in
                            Label(source.lastPathComponent, systemImage: source.hasDirectoryPath ? "folder" : "doc")
                                .help(source.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(maxHeight: 130)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }

            Picker("If a wallpaper already exists", selection: $duplicatePolicy) {
                ForEach(WallpaperImportService.DuplicatePolicy.allCases) { policy in
                    Text(policy.rawValue).tag(policy)
                }
            }
            .disabled(importTask != nil)
            Text("Existing wallpapers are never replaced. “Keep both copies” creates a separate library item.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if importTask != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).lineLimit(2)
                    Spacer()
                    Button("Cancel Import") {
                        progress = "Cancelling…"
                        importTask?.cancel()
                    }
                }
            }
            if let report {
                VStack(alignment: .leading, spacing: 6) {
                    Label(report.cancelled ? "Import cancelled" : "Import finished", systemImage: report.cancelled ? "stop.circle" : "checkmark.circle")
                        .font(.headline)
                    Text("\(report.importedIDs.count) imported · \(report.skipped.count) already in your library · \(report.failures.count) failed")
                        .font(.callout)
                    if report.cancelled {
                        Text("Completed imports were kept. Unfinished copies were removed.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !report.failures.isEmpty {
                        ScrollView {
                            Text(report.failures.joined(separator: "\n\n"))
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Divider()
            HStack {
                Button("Choose Files or Folders…", action: chooseSources)
                    .disabled(importTask != nil)
                Spacer()
                Button(report == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(importTask != nil)
                Button("Import \(sources.count == 1 ? "Item" : "Items")", action: startImport)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sources.isEmpty || importTask != nil || report != nil)
            }
        }
        .padding(24)
        .frame(width: 570)
        .interactiveDismissDisabled(importTask != nil)
    }

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.title = "Choose Wallpaper Content"
        panel.prompt = "Choose"
        panel.message = "Select project folders, a Steam library folder, videos, or HTML files. Image-only wallpapers are not supported."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.allowedContentTypes = [.folder] + (WallpaperImportService.videoExtensions.union(WallpaperImportService.webExtensions))
            .sorted().compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK else { return }
            sources = panel.urls
            report = nil
            errorMessage = nil
        }
    }

    private func startImport() {
        report = nil
        errorMessage = nil
        progress = "Preparing import…"
        let selectedSources = sources
        let policy = duplicatePolicy
        let library = ClientPaths.libraryURL
        importTask = Task { @MainActor in
            do {
                let result = try await service.importItems(selectedSources, into: library, duplicates: policy) { message in
                    await MainActor.run { progress = message }
                }
                report = result
                // Cancellation stops the copy, not the refresh of already committed items.
                let refresh = Task { @MainActor in try await store.refreshLibraryAsync() }
                try await refresh.value
            } catch {
                errorMessage = error.localizedDescription
            }
            importTask = nil
        }
    }
}
