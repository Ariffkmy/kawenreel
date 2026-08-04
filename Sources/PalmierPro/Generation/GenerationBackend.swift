import Foundation
import Combine

/// The RPC layer for the backend
@MainActor
enum GenerationBackend {
    static func subscribe(
        jobId: String
    ) -> AnyPublisher<BackendGenerationJob?, Error>? {
        // Inert until the Kawenreel backend ships a generation endpoint.
        nil
    }

    static func subscribeToProjectActivity(
        projectId: String
    ) -> AnyPublisher<[BackendProjectActivityEntry], Error>? {
        // Inert until the Kawenreel backend ships a project activity endpoint.
        nil
    }

    static func uploadReference(
        fileURL: URL,
        contentType: String,
    ) async throws -> String {
        throw GenerationBackendError.notConfigured
    }

    static func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String? = nil,
    ) async throws -> String {
        throw GenerationBackendError.notConfigured
    }
}

// MARK: - Backend generation types

enum BackendGenerationParams: Encodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .video(let p): try c.encode(p)
        case .image(let p): try c.encode(p)
        case .audio(let p): try c.encode(p)
        case .upscale(let p): try c.encode(p)
        }
    }
}

enum BackendGenerationStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendGenerationJob: Decodable, Sendable {
    let _id: String
    let status: BackendGenerationStatus
    let resultUrls: [String]?
    let errorMessage: String?
    let costCredits: Int?
    let completedAt: Double?
}

enum GenerationBackendError: LocalizedError {
    case notConfigured
    case transport(String)
    case api(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Kawenreel backend not configured."
        case .transport(let s): return s
        case .api(_, _, let message): return message
        }
    }
}

struct BackendProjectActivityEntry: Decodable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable {
        case generation
        case failed
        case refund
    }

    let id: String
    let kind: Kind
    let model: String
    let credits: Int
    let createdAt: Double

    var creditImpact: Int {
        kind == .refund ? -credits : credits
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: createdAt / 1_000)
    }
}

private struct UrlResponse: Decodable, Sendable {
    let url: String
}

private struct SubmitGenerationResult: Decodable, Sendable {
    let jobId: String
}
