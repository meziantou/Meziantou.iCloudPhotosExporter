import Foundation

struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ versionText: String) {
        let trimmed = versionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)

        guard components.count == 3,
              let major = Int(components[0]), major >= 0,
              let minor = Int(components[1]), minor >= 0,
              let patch = Int(components[2]), patch >= 0
        else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }

        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }

        return lhs.patch < rhs.patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }
}

struct UpdateCheckResult {
    let currentVersion: SemanticVersion
    let latestVersion: SemanticVersion
    let releaseURL: URL
    var isUpdateAvailable: Bool {
        latestVersion > currentVersion
    }
}

final class UpdateCheckService {
    var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates() async throws -> UpdateCheckResult {
        guard let currentVersion = SemanticVersion(currentVersionString) else {
            throw UpdateCheckError.invalidCurrentVersion(currentVersionString)
        }

        let url = URL(string: "https://api.github.com/repos/meziantou/Meziantou.iCloudPhotosExporter/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ICloudPhotosExporter/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw UpdateCheckError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let latestVersion = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.invalidLatestVersion(release.tagName)
        }

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
    case invalidCurrentVersion(String)
    case invalidLatestVersion(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatusCode(let code):
            return "GitHub API returned status \(code)."
        case .invalidReleaseURL:
            return "The release URL returned by GitHub is invalid."
        case .invalidCurrentVersion(let version):
            return "Invalid current app version '\(version)'. Expected format is major.minor.patch."
        case .invalidLatestVersion(let version):
            return "Invalid release version '\(version)'. Expected format is vmajor.minor.patch."
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
