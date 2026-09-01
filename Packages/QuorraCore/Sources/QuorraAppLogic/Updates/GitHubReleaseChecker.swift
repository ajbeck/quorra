import Foundation

public struct ReleaseVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    private let components: [Int]

    public init?(_ value: String) {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.first == "v" || candidate.first == "V" {
            candidate.removeFirst()
        }

        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ Int($0) }).count == parts.count else {
            return nil
        }

        self.components = parts.compactMap { Int($0) }
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    public func hash(into hasher: inout Hasher) {
        let lastSignificantIndex = components.lastIndex(where: { $0 != 0 }) ?? components.startIndex
        for component in components[...lastSignificantIndex] {
            hasher.combine(component)
        }
    }

    private static func compare(_ lhs: Self, _ rhs: Self) -> ComparisonResult {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}

public struct GitHubRelease: Hashable, Sendable {
    public let version: ReleaseVersion
    public let tagName: String
    public let releaseURL: URL
    public let diskImageURL: URL?

    public init(
        version: ReleaseVersion,
        tagName: String,
        releaseURL: URL,
        diskImageURL: URL?
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.diskImageURL = diskImageURL
    }
}

public enum AppUpdateAvailability: Hashable, Sendable {
    case updateAvailable(GitHubRelease)
    case upToDate(GitHubRelease)
    case developmentBuild(GitHubRelease)
}

public enum GitHubReleaseCheckError: Error, Equatable, Sendable {
    case invalidRepository
    case invalidResponse
    case httpStatus(Int)
    case malformedRelease
}

extension GitHubReleaseCheckError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "The update repository is not valid."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .httpStatus(let status):
            return "GitHub returned HTTP status \(status)."
        case .malformedRelease:
            return "GitHub returned incomplete release information."
        }
    }
}

public struct GitHubReleaseChecker: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, Int)

    private let endpoint: URL
    private let dataLoader: DataLoader

    public init(
        owner: String,
        repository: String,
        urlSession: URLSession = .shared
    ) throws {
        guard !owner.isEmpty, !repository.isEmpty else {
            throw GitHubReleaseCheckError.invalidRepository
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repository)/releases/latest"
        guard let endpoint = components.url else {
            throw GitHubReleaseCheckError.invalidRepository
        }

        self.endpoint = endpoint
        self.dataLoader = { request in
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GitHubReleaseCheckError.invalidResponse
            }
            return (data, response.statusCode)
        }
    }

    init(endpoint: URL, dataLoader: @escaping DataLoader) {
        self.endpoint = endpoint
        self.dataLoader = dataLoader
    }

    public func check(currentVersion: ReleaseVersion) async throws -> AppUpdateAvailability {
        let release = try await latestRelease()
        if currentVersion < release.version {
            return .updateAvailable(release)
        }
        if currentVersion > release.version {
            return .developmentBuild(release)
        }
        return .upToDate(release)
    }

    public func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Quorra", forHTTPHeaderField: "User-Agent")

        let (data, statusCode) = try await dataLoader(request)
        guard (200..<300).contains(statusCode) else {
            throw GitHubReleaseCheckError.httpStatus(statusCode)
        }

        let response: ReleaseResponse
        do {
            response = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        } catch {
            throw GitHubReleaseCheckError.malformedRelease
        }

        guard let version = ReleaseVersion(response.tagName),
              let releaseURL = secureURL(response.htmlURL) else {
            throw GitHubReleaseCheckError.malformedRelease
        }

        let preferredAssetName = "Quorra-\(version).dmg"
        let diskImageURL = response.assets
            .filter { $0.state == "uploaded" }
            .filter { $0.name.lowercased().hasSuffix(".dmg") || $0.contentType == "application/x-apple-diskimage" }
            .sorted { lhs, rhs in
                let lhsIsPreferred = lhs.name == preferredAssetName
                let rhsIsPreferred = rhs.name == preferredAssetName
                if lhsIsPreferred != rhsIsPreferred { return lhsIsPreferred }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .compactMap { secureURL($0.browserDownloadURL) }
            .first

        return GitHubRelease(
            version: version,
            tagName: response.tagName,
            releaseURL: releaseURL,
            diskImageURL: diskImageURL
        )
    }
}

private struct ReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let state: String
        let contentType: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case state
            case contentType = "content_type"
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private func secureURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
    return url
}
