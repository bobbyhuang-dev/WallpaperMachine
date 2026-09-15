import AppKit
import SwiftUI

struct WorkshopPageView: View {
    @Environment(BridgeStore.self) private var bridge
    @EnvironmentObject private var navigation: ControlPanelNavigation
    @Bindable var workshop: WorkshopStore
    @State private var showSetup = false
    @State private var columnCount = 1
    @FocusState private var searchIsFocused: Bool
    @FocusState private var focusedItemID: String?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
            header
            Divider()
                searchControls(compact: geometry.size.width < 380)
                results
            Divider()
            footer
        }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Workshop")
        .task { if !workshop.hasLoaded && !workshop.isLoading { workshop.search() } }
        .sheet(isPresented: $showSetup) { WorkshopSetupView(workshop: workshop) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discover your next desktop")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Steam Workshop · Community-made wallpapers, in MacWallpaperEngine")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Download setup", systemImage: "person.badge.key") { showSetup = true }
                Spacer(minLength: 0)
                Link(destination: workshop.browseURL) {
                    Image(systemName: "arrow.up.right.square")
                }
                .accessibilityLabel("Open Steam Workshop in your browser")
                .help("Open Steam Workshop in your browser")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func searchControls(compact: Bool) -> some View {
        @Bindable var workshop = workshop
        let filtersLayout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { searchIsFocused = true } label: {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Search Steam Workshop")
                    .help("Search Steam Workshop")
                    TextField("Search Steam Workshop", text: $workshop.searchText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .focused($searchIsFocused)
                        .onSubmit { workshop.search() }
                        .accessibilityIdentifier("workshop.search")
                    if !workshop.searchText.isEmpty {
                        Button { workshop.searchText = ""; workshop.search() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                        .help("Clear search")
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                Button("Search") { workshop.search() }
            }
            filtersLayout {
                Picker("Type", selection: $workshop.kind) {
                    ForEach(WorkshopKind.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Type")
                .help("Type")
                Picker("Sort", selection: $workshop.sort) {
                    ForEach(WorkshopSort.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Sort")
                .help("Sort")
                if !compact { Spacer(minLength: 0) }
                Group {
                    if workshop.hasLoaded {
                        Text("\(workshop.totalCount.formatted()) results")
                            .help("\(workshop.totalCount.formatted()) matching wallpapers")
                    } else {
                        Text("Live results from Steam")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .onChange(of: workshop.kind) { workshop.search() }
        .onChange(of: workshop.sort) { workshop.search() }
    }

    private func searchError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("Retry") { workshop.retrySearch() }
                Spacer(minLength: 0)
                Button { workshop.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss search error")
                    .help("Dismiss search error")
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var results: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if let error = workshop.errorMessage {
                        searchError(error).padding(12)
                    }
                    if workshop.isLoading && !workshop.items.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading results…").font(.callout).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Cancel") { workshop.cancelSearch() }
                        }
                        .padding(12)
                    }
                    if workshop.isLoading && workshop.items.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Discovering wallpapers on Steam…").foregroundStyle(.secondary)
                            Button("Cancel") { workshop.cancelSearch() }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(0, geometry.size.height - 32))
                        .padding(16)
                    } else if workshop.items.isEmpty {
                        ControlPanelEmptyState(workshop.hasLoaded ? "No wallpapers found" : "Explore Steam Workshop",
                            systemImage: "sparkles.rectangle.stack",
                            description: Text(workshop.hasLoaded ? "Try a different search or wallpaper type." : "Browse public wallpapers without a Steam API key. Download only with an account that owns Wallpaper Engine.")) {
                            Button("Browse wallpapers") { workshop.search() }.buttonStyle(.borderedProminent)
                            Link("Open Steam Workshop", destination: workshop.browseURL)
                        }
                        .frame(minHeight: max(0, geometry.size.height - 32))
                        .padding(16)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 164, maximum: 240), spacing: 12)], spacing: 12) {
                            ForEach(workshop.items) { item in
                                WorkshopCard(item: item, installed: isInstalled(item.id),
                                             download: workshop.downloader.download(for: item.id),
                                             isSelected: workshop.selectedItem?.id == item.id,
                                             focusedItemID: $focusedItemID) {
                                    workshop.selectedItem = item
                                    focusedItemID = item.id
                                }
                                .id(item.id)
                                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { key in
                                    moveFocus(key, proxy: proxy)
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .onGeometryChange(for: Int.self) { geometry in
                            max(1, Int((geometry.size.width + 12) / (164 + 12)))
                        } action: { columnCount = $0 }
                        .padding(12)
                    }
                }
                .scrollPosition(id: $navigation.workshopScrollID)
            }
        }
    }


    private var footer: some View {
        HStack(spacing: 8) {
            Button { workshop.loadPage(workshop.page - 1) } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(workshop.page <= 1 || workshop.isLoading)
            .labelStyle(.iconOnly)
            .help("Previous")
            Spacer(minLength: 0)
            Text("Page \(workshop.page) of \(workshop.totalPages)")
                .monospacedDigit().font(.callout)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity)
            Spacer(minLength: 0)
            Button { workshop.loadPage(workshop.page + 1) } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(workshop.page >= workshop.totalPages || workshop.isLoading)
            .labelStyle(.iconOnly)
            .help("Next")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func moveFocus(_ key: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              let focusedItemID,
              let index = workshop.items.firstIndex(where: { $0.id == focusedItemID }) else { return .ignored }
        let offset: Int
        switch key.key {
        case .leftArrow: offset = -1
        case .rightArrow: offset = 1
        case .upArrow: offset = -columnCount
        case .downArrow: offset = columnCount
        default: return .ignored
        }
        let nextIndex = min(max(index + offset, 0), workshop.items.count - 1)
        let nextID = workshop.items[nextIndex].id
        proxy.scrollTo(nextID)
        self.focusedItemID = nextID
        return .handled
    }

    private func isInstalled(_ id: String) -> Bool {
        bridge.librarySnapshot.wallpapers.contains { $0.id == id }
    }
}

private struct WorkshopCard: View {
    let item: WorkshopItem
    let installed: Bool
    let download: WorkshopDownload?
    let isSelected: Bool
    let focusedItemID: FocusState<String?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                WorkshopPreview(url: item.previewURL)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if let download, download.isPending {
                            Label(download.isQueued ? "Queued" : "Downloading", systemImage: download.isQueued ? "clock" : "arrow.down.circle")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                        } else if installed {
                            Label("In Library", systemImage: "checkmark.circle")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.headline).lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        if item.kind == .application || item.kind == .web {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        Text(LocalizedStringKey(item.kind == .all ? "Wallpaper" : item.kind.rawValue))
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }.padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focusedItemID, equals: item.id)
        .onKeyPress(.return, phases: .down) { key in
            guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
            action()
            return .handled
        }
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(download?.isPending == true ? Text(download?.status ?? "") : installed ? Text("In Library") : Text(""))
        .accessibilityHint(Text(LocalizedStringKey(item.kind.compatibility)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("workshop.item.\(item.id)")
        .help(item.title)
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
            Color(nsColor: .quaternaryLabelColor)
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
