import Foundation

enum RecoveryScanProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg
    case photos

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpeg: "JPEG only"
        case .photos: "JPEG + camera RAW"
        }
    }

    var shortDescription: String {
        switch self {
        case .jpeg:
            "Recover JPEG photos only."
        case .photos:
            "Recover JPEG plus common Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax, and Sigma RAW formats."
        }
    }

    var resultDescription: String {
        switch self {
        case .jpeg: "JPEG files"
        case .photos: "photo files"
        }
    }

    /// PhotoRec's file-option names are format families, not always filename
    /// extensions. In particular, `tif` also covers TIFF-based RAW formats such
    /// as CR2, DNG, NEF, PEF, and Sony's ARW/SR2 family.
    var photoRecFileFamilies: [String] {
        switch self {
        case .jpeg:
            ["jpg"]
        case .photos:
            ["jpg", "tif", "crw", "orf", "raf", "raw", "rw2", "x3f"]
        }
    }
}

struct RecoverySession: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case ready
        case scanning
        case completed
        case cancelled
        case interrupted
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
    var scanProfile: RecoveryScanProfile? = nil

    var sourceImageURL: URL { URL(fileURLWithPath: sourceImagePath) }
    var sessionDirectoryURL: URL { URL(fileURLWithPath: sessionDirectoryPath) }
    var manifestURL: URL { sessionDirectoryURL.appendingPathComponent("session.json") }
    var logURL: URL { sessionDirectoryURL.appendingPathComponent("photorec.log") }
    var runnerLogURL: URL { sessionDirectoryURL.appendingPathComponent("runner.log") }
    var recoveredOutputBaseURL: URL { sessionDirectoryURL.appendingPathComponent("recovered") }
    var effectiveScanProfile: RecoveryScanProfile { scanProfile ?? .jpeg }
}

struct RecoveredFile: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case jpeg = "JPEG"
        case rawOrTIFF = "RAW / TIFF"
        case other = "Other"

        var systemImage: String {
            switch self {
            case .jpeg: "photo"
            case .rawOrTIFF: "camera.aperture"
            case .other: "doc"
            }
        }
    }

    enum ValidationStatus: String, Codable, Sendable {
        case notChecked
        case readable
        case previewReadable
        case possiblyPartial
    }

    static let rawOrTIFFExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff",
        "iiq", "k25", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf",
        "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "tif", "tiff", "x3f"
    ]

    let id: UUID
    let path: String
    let byteCount: Int64
    var validationStatus: ValidationStatus

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
    var kind: Kind {
        let fileExtension = url.pathExtension.lowercased()
        if ["jpg", "jpeg"].contains(fileExtension) {
            return .jpeg
        }
        if Self.rawOrTIFFExtensions.contains(fileExtension) {
            return .rawOrTIFF
        }
        return .other
    }
}
