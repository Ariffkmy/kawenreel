@preconcurrency import Combine
import Foundation

/// Cloud transcription RPC layer. Inert until the Kawenreel backend ships a
/// transcription endpoint — callers fall back to on-device transcription.
enum TranscriptionBackend {
    @MainActor
    static func submit(
        storageId: String,
        durationSeconds: Double,
        language: String?,
        projectId: String?
    ) async throws -> BackendTranscriptionSubmit {
        throw GenerationBackendError.notConfigured
    }

    @MainActor
    static func waitForResult(jobId: String) async throws -> TranscriptionResult {
        throw GenerationBackendError.notConfigured
    }
}

enum BackendTranscriptionStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendTranscriptionSubmit: Decodable, Sendable {
    let jobId: String
}

struct BackendTranscriptionJob: Decodable, Sendable {
    let id: String
    let status: BackendTranscriptionStatus
    let errorMessage: String?
}

enum TranscriptionBackendError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
