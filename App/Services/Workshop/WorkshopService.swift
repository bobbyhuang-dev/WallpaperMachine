import Foundation

struct WorkshopItem: Identifiable, Sendable {
    let id: String
    let title: String
    let creator: String
    let summary: String
    let previewURL: URL?
    let tags: [String]
    let size: Int64
    let subscriptions: Int

    var kind: WorkshopKind {
        WorkshopKind.allCases.first { $0 != .all && tags.contains($0.rawValue) } ?? .all
    }
    var pageURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")! }
}

enum WorkshopKind: String, CaseIterable, Identifiable, Sendable {
    case all = "All types", scene = "Scene", video = "Video", web = "Web", application = "Application"
    var id: String { rawValue }
    var compatibility: String {
        switch self {
        case .scene: String(localized: "Scene · experimental renderer")
        case .video: String(localized: "Video · codec dependent")
        case .web: String(localized: "Web · built-in web view")
        case .application: String(localized: "Application · unsupported on macOS")
        case .all: String(localized: "Compatibility checked after download")
        }
    }
}

enum WorkshopSort: String, CaseIterable, Identifiable, Sendable {
    case trending = "trend", popular = "totaluniquesubscribers", newest = "mostrecent", relevance = "textsearch"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trending: String(localized: "Trending this week")
        case .popular: String(localized: "Most subscribed")
        case .newest: String(localized: "Newest")
        case .relevance: String(localized: "Relevance")
        }
    }
}

struct WorkshopPage: Sendable {
    let items: [WorkshopItem]
    let page: Int
    let totalPages: Int
    let totalCount: Int
}

struct WorkshopFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

actor WorkshopService {
    /// Steam's public browse page clamps `numperpage` to 30 and `total_pages` to 1000, so a single
    /// query can only ever expose the first 30,000 results; the panel explains that cap.
    static let pageSize = 30
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    static func browseURL(search: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = []) -> URL {
        var url = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        url.queryItems = [
            URLQueryItem(name: "appid", value: "431960"),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "browsesort", value: sort.rawValue),
            URLQueryItem(name: "searchtext", value: search),
            URLQueryItem(name: "p", value: String(max(1, page))),
            URLQueryItem(name: "numperpage", value: String(Self.pageSize)),
            URLQueryItem(name: "days", value: "7"),
            URLQueryItem(name: "l", value: "english")
        ]
        if kind != .all { url.queryItems?.append(URLQueryItem(name: "requiredtags[]", value: kind.rawValue)) }
        // Steam requires every selected tag, including the wallpaper type.
        var seen: Set<String> = kind == .all ? [] : [kind.rawValue]
        for tag in tags where seen.insert(tag).inserted {
            url.queryItems?.append(URLQueryItem(name: "requiredtags[]", value: tag))
        }
        return url.url!
    }

    func browse(search: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = []) async throws -> WorkshopPage {
        var request = URLRequest(url: Self.browseURL(search: search, kind: kind, sort: sort, page: page, tags: tags))
        request.timeoutInterval = 35
        request.setValue("MacWallpaperEngine/1.0 (macOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkshopFailure(message: String(localized: "Steam could not load the Workshop. Check your connection or open Steam in your browser, then retry."))
        }
        guard data.count < 12_000_000, let html = String(data: data, encoding: .utf8) else {
            throw WorkshopFailure(message: String(localized: "Steam returned an unreadable Workshop page. Try again or browse on Steam."))
        }
        return try Self.decodePage(html)
    }

    // Steam's public server-rendered page contains a JSON string, not an executable API response.
    // Decode the JSON layers without evaluating any page JavaScript.
    static func decodePage(_ html: String) throws -> WorkshopPage {
        let regex = try NSRegularExpression(pattern: #"window\.SSR\.renderContext\s*=\s*JSON\.parse\(("(?:\\.|[^"\\])*")\)"#)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let encoded = String(html[range]).data(using: .utf8),
              let contextString = try JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed) as? String,
              let context = try JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any],
              let queryString = context["queryData"] as? String,
              let queryData = try JSONSerialization.jsonObject(with: Data(queryString.utf8)) as? [String: Any],
              let queries = queryData["queries"] as? [[String: Any]],
              let query = queries.first(where: { ($0["queryKey"] as? [Any])?.first as? String == "workshop_browse" }),
              let state = query["state"] as? [String: Any],
              let result = state["data"] as? [String: Any],
              let rows = result["results"] as? [[String: Any]],
              (result["eresult"] as? Int) == 1 else {
            throw WorkshopFailure(message: String(localized: "Steam changed its public page or requires a browser sign-in. Open Workshop on Steam, then retry."))
        }
        var creators: [String: String] = [:]
        for query in queries {
            guard let key = query["queryKey"] as? [String], key.count == 2, key[0] == "PlayerLinkDetails",
                  let state = query["state"] as? [String: Any], let data = state["data"] as? [String: Any],
                  let publicData = data["public_data"] as? [String: Any], let name = publicData["persona_name"] as? String else { continue }
            creators[key[1]] = name
        }
        var seen = Set<String>()
        let items = rows.compactMap { row -> WorkshopItem? in
            guard let id = row["publishedfileid"] as? String, UInt64(id) != nil,
                  row["consumer_appid"] as? Int == 431960,
                  let title = row["title"] as? String, seen.insert(id).inserted else { return nil }
            let preview = (row["preview_url"] as? String).flatMap(URL.init(string:))
            return WorkshopItem(
                id: id, title: title, creator: creators[row["creator"] as? String ?? ""] ?? String(localized: "Workshop creator"),
                summary: row["short_description"] as? String ?? "", previewURL: preview?.scheme == "https" ? preview : nil,
                tags: (row["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String },
                size: Int64(row["file_size"] as? String ?? "") ?? 0,
                subscriptions: row["subscriptions"] as? Int ?? 0
            )
        }
        return WorkshopPage(items: items, page: result["current_page"] as? Int ?? 1,
                            totalPages: max(1, result["total_pages"] as? Int ?? 1), totalCount: result["total_count"] as? Int ?? 0)
    }
}
