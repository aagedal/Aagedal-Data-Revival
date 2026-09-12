import Foundation

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
