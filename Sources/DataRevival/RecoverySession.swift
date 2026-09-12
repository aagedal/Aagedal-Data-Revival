import Foundation

struct RecoverySession: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case ready
        case scanning
        case completed
        case cancelled
        case failed
    }

    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let sourceImagePath: String
    let sessionDirectoryPath: String
    var status: Status
    var recoveredFiles: [RecoveredFile]
    var failureMessage: String?

    var sourceImageURL: URL { URL(fileURLWithPath: sourceImagePath) }
    var sessionDirectoryURL: URL { URL(fileURLWithPath: sessionDirectoryPath) }
    var manifestURL: URL { sessionDirectoryURL.appendingPathComponent("session.json") }
    var logURL: URL { sessionDirectoryURL.appendingPathComponent("photorec.log") }
    var runnerLogURL: URL { sessionDirectoryURL.appendingPathComponent("runner.log") }
    var recoveredOutputBaseURL: URL { sessionDirectoryURL.appendingPathComponent("recovered") }
}

struct RecoveredFile: Codable, Identifiable, Sendable, Equatable {
    enum ValidationStatus: String, Codable, Sendable {
        case notChecked
        case readable
        case possiblyPartial
    }

    let id: UUID
    let path: String
    let byteCount: Int64
    var validationStatus: ValidationStatus

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
}
