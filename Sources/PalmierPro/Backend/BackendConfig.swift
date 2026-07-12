import Foundation

enum BackendConfig {
    /// Sample-project library endpoint (unset until kawenreel.com hosts one).
    static let sampleLibraryURL: URL? = string("KawenreelSampleLibraryURL").flatMap { URL(string: $0) }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
