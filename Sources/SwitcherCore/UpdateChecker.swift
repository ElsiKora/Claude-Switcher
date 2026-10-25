public import Foundation

/// Asks GitHub for the latest release of this app. Nothing about the user or
/// their accounts goes along.
public struct UpdateChecker: Sendable {
    /// `owner/name`, empty while the app has no public release page.
    public let repository: String
    let session: URLSession

    public init(repository: String, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    public var isConfigured: Bool { repository.contains("/") }

    public struct Release: Sendable, Equatable {
        public var version: String
        public var page: URL
        public var archive: URL?
        public var checksum: URL?
    }

    public func latest() async throws -> Release {
        struct Body: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: URL
            }
            var tag_name: String
            var html_url: URL
            var assets: [Asset]
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        let zip = body.assets.first { $0.name.hasSuffix(".zip") }
        return Release(
            version: body.tag_name.trimmingPrefix("v").description,
            page: body.html_url,
            archive: zip?.browser_download_url,
            checksum: zip.flatMap { z in body.assets.first { $0.name == z.name + ".sha256" } }?.browser_download_url)
    }

    /// Whether version `a` is newer than `b`, comparing dot-separated numbers.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
