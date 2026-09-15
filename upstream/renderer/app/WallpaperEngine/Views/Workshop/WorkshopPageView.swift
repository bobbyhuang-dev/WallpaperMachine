import AppKit
import SwiftUI

struct WorkshopPageView: View {
    @Environment(BridgeStore.self) private var bridge
    @Bindable var workshop: WorkshopStore
    @State private var selectedItem: WorkshopItem?
    @State private var showSetup = false
    @State private var showAssetsSetup = false

    var body: some View {
        @Bindable var workshop = workshop
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Steam Workshop", text: $workshop.searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { workshop.search() }
                        .accessibilityIdentifier("workshop.search")
                    if !workshop.searchText.isEmpty {
                        Button { workshop.searchText = ""; workshop.search() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                    }
                }
                .padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                Button("Search") { workshop.search() }.keyboardShortcut(.return, modifiers: [])
                Picker("Type", selection: $workshop.kind) {
                    ForEach(WorkshopKind.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 150)
                Picker("Sort", selection: $workshop.sort) {
                    ForEach(WorkshopSort.allCases) { Text($0.title).tag($0) }
                }.frame(width: 210)
            }.padding(20)
            .onChange(of: workshop.kind) { workshop.search() }
            .onChange(of: workshop.sort) { workshop.search() }

            if let error = workshop.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { workshop.search(page: workshop.page) }
                    Button { workshop.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(14).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let message = workshop.applyMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(.bottom, 10)
            }
            if !workshop.downloader.downloads.isEmpty {
                downloadsPanel
            }
            if workshop.isLoading && workshop.items.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Discovering wallpapers on Steam…").foregroundStyle(.secondary)
                    Button("Cancel") { workshop.cancelSearch() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workshop.items.isEmpty {
                ContentUnavailableView {
                    Label(workshop.hasLoaded ? "No wallpapers found" : "Explore Steam Workshop", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text(workshop.hasLoaded ? "Try a different search or wallpaper type." : "Browse public wallpapers without a Steam API key. Download only with an account that owns Wallpaper Engine.")
                } actions: {
                    Button("Browse wallpapers") { workshop.search() }.buttonStyle(.borderedProminent)
                    Link("Open Steam Workshop", destination: workshop.browseURL)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 18)], spacing: 18) {
                        ForEach(workshop.items) { item in
                            WorkshopCard(item: item, installed: isInstalled(item.id), download: workshop.downloader.download(for: item.id)) { selectedItem = item }
                        }
                    }.padding(20).padding(.top, -8)
                }.overlay(alignment: .top) {
                    if workshop.isLoading {
                        HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Loading results…"); Button("Cancel") { workshop.cancelSearch() } }
                            .padding(12).background(.regularMaterial, in: Capsule()).padding(8)
                    }
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Workshop")
        .task { if !workshop.hasLoaded && !workshop.isLoading { workshop.search() } }
        .sheet(item: $selectedItem) { item in
            WorkshopDetailView(item: item, workshop: workshop, installed: isInstalled(item.id))
                .environment(bridge)
        }
        .sheet(isPresented: $showSetup) { WorkshopSetupView() }
        .sheet(isPresented: $showAssetsSetup) { SceneAssetsSetupView(workshop: workshop).environment(bridge) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 30)).foregroundStyle(.tint)
                .frame(width: 56, height: 56).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Discover your next desktop").font(.system(size: 25, weight: .semibold))
                Text("Steam Workshop · Community-made wallpapers, in MacWallpaperEngine").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Download setup", systemImage: "person.badge.key") { showSetup = true }
            Link(destination: workshop.browseURL) { Image(systemName: "arrow.up.right.square") }.help("Open Steam Workshop in your browser")
        }.padding(24)
    }

    private var downloadsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle").font(.callout.weight(.semibold))
                Spacer()
                Text("\(workshop.downloader.activeCount)/\(workshop.downloader.maximumConcurrentDownloads) active · \(workshop.downloader.queuedCount) queued")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(workshop.downloader.downloads) { download in
                        WorkshopDownloadRow(download: download) {
                            if let item = download.item { selectedItem = item }
                            else { showAssetsSetup = true }
                        } cancel: {
                            workshop.downloader.cancel(download)
                        }
                    }
                }
            }.frame(height: min(CGFloat(workshop.downloader.downloads.count) * 78, 190))
        }
        .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20).padding(.bottom, 12)
        .accessibilityIdentifier("workshop.downloads")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(workshop.hasLoaded ? "\(workshop.totalCount.formatted()) matching wallpapers" : "Live results from Steam")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { workshop.search(page: workshop.page - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(workshop.page <= 1 || workshop.isLoading)
            Text("Page \(workshop.page) of \(workshop.totalPages)").monospacedDigit().font(.callout)
            Button { workshop.search(page: workshop.page + 1) } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(workshop.page >= workshop.totalPages || workshop.isLoading)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func isInstalled(_ id: String) -> Bool {
        bridge.librarySnapshot.wallpapers.contains { $0.id == id } || workshop.downloader.download(for: id)?.worker.downloadedID == id
    }
}

private struct WorkshopDownloadRow: View {
    let download: WorkshopDownload
    let open: () -> Void
    let cancel: () -> Void

    private var needsAuthentication: Bool {
        download.isPending && !download.isQueued && (download.worker.prompt != nil || download.worker.steamGuardChallenge != nil)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(download.item?.title ?? "Scene assets").font(.callout.weight(.medium)).lineLimit(1)
                        Text(download.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = download.worker.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                    } else if needsAuthentication {
                        Label("Sign-in needed · \(download.status)", systemImage: "person.badge.key").foregroundStyle(.orange).lineLimit(2)
                    } else if let warning = download.worker.sessionWarning {
                        Label(warning, systemImage: "exclamationmark.shield").foregroundStyle(.orange).lineLimit(2)
                    } else {
                        Text(download.status).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if download.isPending && !download.isQueued {
                        ProgressView(value: download.progress).progressViewStyle(.linear)
                            .accessibilityLabel("Download progress")
                    }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(download.item == nil ? "Open scene assets setup" : "Open wallpaper details")
            if download.isPending {
                Button("Cancel", role: .cancel, action: cancel).controlSize(.small)
                    .accessibilityLabel("Cancel \(download.item?.title ?? "scene assets")")
            }
        }.padding(.vertical, 3)
    }
}

private struct WorkshopCard: View {
    let item: WorkshopItem
    let installed: Bool
    let download: WorkshopDownload?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                WorkshopPreview(url: item.previewURL)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if let download, download.isPending {
                            Label(download.isQueued ? "Queued" : "Downloading", systemImage: download.isQueued ? "clock" : "arrow.down.circle")
                                .font(.caption.weight(.medium)).padding(7).background(.regularMaterial, in: Capsule()).padding(10)
                        } else if installed {
                            Label("In Library", systemImage: "checkmark").font(.caption.weight(.medium)).padding(7).background(.regularMaterial, in: Capsule()).padding(10)
                        }
                    }
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title).font(.headline).lineLimit(2).frame(height: 38, alignment: .topLeading)
                    Text(item.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        Text(item.kind == .all ? "Wallpaper" : item.kind.rawValue).font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor.opacity(0.1), in: Capsule())
                        Spacer()
                        Label(item.subscriptions.formatted(.number.notation(.compactName)), systemImage: "person.2")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.kind.compatibility).font(.caption2).foregroundStyle(item.kind == .application || item.kind == .web ? Color.orange : Color.secondary).lineLimit(1)
                }.padding(13)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(hovered ? Color.accentColor.opacity(0.7) : .primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(hovered ? 0.13 : 0.04), radius: hovered ? 8 : 3, y: 3)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel("\(item.title), \(item.kind.compatibility)\(installed ? ", in library" : "")\(download?.isPending == true ? ", \(download?.status ?? "")" : "")")
            .accessibilityIdentifier("workshop.item.\(item.id)")
    }
}

struct WorkshopPreview: View {
    let url: URL?
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: placeholder(symbol: "photo.badge.exclamationmark")
                default: placeholder(symbol: "photo")
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
    private func placeholder(symbol: String) -> some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.18), .cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}
