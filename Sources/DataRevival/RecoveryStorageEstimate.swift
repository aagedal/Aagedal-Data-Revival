import Foundation

enum RecoveryVolumeCapacity {
    /// `volumeAvailableCapacityForImportantUsage` can report zero for writable
    /// temporary or externally managed volumes even when ordinary free-space
    /// accounting is available. Prefer it when positive, then fall back to the
    /// conservative non-purgeable capacity rather than treating the value as a
    /// genuinely full disk.
    static func available(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let ordinary = values.volumeAvailableCapacity, ordinary >= 0 {
            return Int64(ordinary)
        }
        return values.volumeAvailableCapacityForImportantUsage
    }
}

struct RecoveryStorageEstimate: Sendable, Equatable {
    let sourceByteCount: Int64

    var cardImageByteCount: Int64 { sourceByteCount }
    var recoveredOutputByteCount: Int64 { sourceByteCount }

    var completeWorkflowByteCount: Int64 {
        let (total, overflow) = sourceByteCount.addingReportingOverflow(sourceByteCount)
        return overflow ? .max : total
    }

    init(sourceByteCount: Int64) {
        self.sourceByteCount = max(0, sourceByteCount)
    }

    func validateRecoveryOutputCapacity(_ availableCapacity: Int64?) throws {
        guard let availableCapacity, availableCapacity >= 0 else {
            throw RecoveryStorageError.destinationCapacityUnknown
        }
        guard availableCapacity >= recoveredOutputByteCount else {
            throw RecoveryStorageError.insufficientRecoverySpace(
                required: recoveredOutputByteCount,
                available: availableCapacity
            )
        }
    }
}

enum RecoveryStorageError: LocalizedError, Equatable {
    case destinationCapacityUnknown
    case insufficientRecoverySpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .destinationCapacityUnknown:
            "The available space on the recovery destination could not be determined."
        case let .insufficientRecoverySpace(required, available):
            "The recovery destination has \(available.formatted(.byteCount(style: .file))) available. Reserve at least \(required.formatted(.byteCount(style: .file))) for recovered output from this image."
        }
    }
}
