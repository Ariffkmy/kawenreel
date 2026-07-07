import Foundation

/// Color grading learned from the reference dataset by scripts/build_color_profile.py.
/// `overall` is the bundled color fallback when the user has no style references;
/// `looks` are the dataset's distinct grading styles.
struct DomainColorProfile: Decodable, Sendable {
    let domain: String
    let videosAnalyzed: Int
    let overall: ColorSignature
    let looks: [Look]

    struct Look: Decodable, Sendable {
        let id: String
        let name: String
        let videoCount: Int
        let lutFile: String?
        let signature: ColorSignature
    }

    func look(_ id: String) -> Look? {
        looks.first { $0.id == id || $0.name == id }
    }
}

enum DomainColorStore {
    @MainActor private static var cache: [String: DomainColorProfile?] = [:]

    @MainActor
    static func load(_ domain: String) -> DomainColorProfile? {
        if let hit = cache[domain] { return hit }
        guard let url = DomainResources.url("DomainPacks/\(domain)_colors.json"),
              let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(DomainColorProfile.self, from: data) else {
            cache[domain] = DomainColorProfile?.none
            return nil
        }
        cache[domain] = profile
        return profile
    }

    /// Absolute path of a look's bundled .cube LUT, or nil if absent.
    @MainActor
    static func lutURL(fileName: String) -> URL? {
        DomainResources.url("DomainPacks/LUTs/\(fileName)")
    }
}
