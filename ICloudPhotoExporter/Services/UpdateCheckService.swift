import AppKit
import Foundation
import OSLog

struct UpdateCheckResult {
    let currentVersion: String
    let latestVersion: String
    let releaseURL: URL
    var isUpdateAvailable: Bool {
        latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending
    }
}

final class UpdateCheckService {
    private let logger = Logger(subsystem: "com.meziantou.icloudphotoexporter", category: "UpdateCheckService")

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    func checkForUpdates() async throws -> UpdateCheckResult {
        let url = URL(string: "https://api.github.com/repos/meziantou/Meziantou.iCloudPhotoExporter/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ICloudPhotoExporter/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw UpdateCheckError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let tagName = release.tagName
        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        guard let releaseURL = URL(string: release.htmlURL) else {
            throw UpdateCheckError.invalidReleaseURL
        }

        return UpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseURL: releaseURL
        )
    }
}

enum UpdateCheckError: LocalizedError {
    case unexpectedStatusCode(Int)
    case invalidReleaseURL

    var errorDescription: String? {
        switch self {
        case .unexpectedStatusCode(let code):
            return "GitHub API returned status \(code)."
        case .invalidReleaseURL:
            return "The release URL returned by GitHub is invalid."
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
