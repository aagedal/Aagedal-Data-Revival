import Foundation
import DiskArbitration

protocol DiskLifecycleControlling: Sendable {
    func unmountWholeDisk(bsdName: String) async throws
    func mountWholeDisk(bsdName: String) async throws
    func ejectWholeDisk(bsdName: String) async throws
}

enum DiskLifecycleOperation: String, Sendable, Equatable {
    case unmount
    case mount
    case eject
}

enum DiskLifecycleError: LocalizedError, Equatable {
    case sessionUnavailable
    case diskUnavailable(String)
    case rejected(operation: DiskLifecycleOperation, status: Int32, message: String?)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            "macOS Disk Arbitration could not be started."
        case let .diskUnavailable(bsdName):
            "The recovery source \(bsdName) is no longer available."
        case let .rejected(operation, _, message):
            if let message, !message.isEmpty {
                "macOS could not \(operation.rawValue) the recovery source: \(message)"
            } else {
                "macOS could not \(operation.rawValue) the recovery source."
            }
        }
    }
}

/// Performs non-forced whole-disk lifecycle operations through Disk Arbitration.
/// Raw-device access is authorized separately through macOS `authopen`; this
/// type only establishes and restores the safe unmounted state around imaging.
struct DiskArbitrationLifecycleController: DiskLifecycleControlling {
    func unmountWholeDisk(bsdName: String) async throws {
        try await perform(.unmount, bsdName: bsdName)
    }

    func mountWholeDisk(bsdName: String) async throws {
        try await perform(.mount, bsdName: bsdName)
    }

    func ejectWholeDisk(bsdName: String) async throws {
        try await perform(.eject, bsdName: bsdName)
    }

    private func perform(_ operation: DiskLifecycleOperation, bsdName: String) async throws {
        try Task.checkCancellation()
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw DiskLifecycleError.sessionUnavailable
        }
        guard let disk = bsdName.withCString({
            DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
        }) else {
            throw DiskLifecycleError.diskUnavailable(bsdName)
        }

        try await withCheckedThrowingContinuation { continuation in
            let request = DiskLifecycleRequest(
                operation: operation,
                session: session,
                continuation: continuation
            )
            let context = Unmanaged.passRetained(request).toOpaque()
            DASessionSetDispatchQueue(session, request.queue)

            switch operation {
            case .unmount:
                DADiskUnmount(
                    disk,
                    DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                    diskLifecycleRequestFinished,
                    context
                )
            case .mount:
                DADiskMount(
                    disk,
                    nil,
                    DADiskMountOptions(kDADiskMountOptionWhole),
                    diskLifecycleRequestFinished,
                    context
                )
            case .eject:
                DADiskEject(
                    disk,
                    DADiskEjectOptions(kDADiskEjectOptionDefault),
                    diskLifecycleRequestFinished,
                    context
                )
            }
        }
    }
}

private final class DiskLifecycleRequest: @unchecked Sendable {
    let operation: DiskLifecycleOperation
    let session: DASession
    let queue = DispatchQueue(label: "com.aagedal.DataRevival.disk-lifecycle")
    let continuation: CheckedContinuation<Void, Error>

    init(
        operation: DiskLifecycleOperation,
        session: DASession,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.operation = operation
        self.session = session
        self.continuation = continuation
    }
}

private func diskLifecycleRequestFinished(
    _ disk: DADisk,
    _ dissenter: DADissenter?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let request = Unmanaged<DiskLifecycleRequest>.fromOpaque(context).takeRetainedValue()
    DASessionSetDispatchQueue(request.session, nil)

    if let dissenter {
        let status = Int32(DADissenterGetStatus(dissenter))
        let message = DADissenterGetStatusString(dissenter) as String?
        request.continuation.resume(
            throwing: DiskLifecycleError.rejected(
                operation: request.operation,
                status: status,
                message: message
            )
        )
    } else {
        request.continuation.resume()
    }
}

enum CardPostImagingAction: Sendable, Equatable {
    case remount
    case eject
}

/// Owns the disk-lifecycle half of the source-access sequence. Identity is checked
/// before unmount and resolved again after unmount so a reused BSD name cannot
/// silently redirect the subsequent privileged request to another device.
struct CardImagingSourceCoordinator: Sendable {
    typealias DeviceResolver = @Sendable (String) -> StorageDevice?

    private let lifecycle: any DiskLifecycleControlling
    private let resolveDevice: DeviceResolver

    init(
        lifecycle: any DiskLifecycleControlling = DiskArbitrationLifecycleController(),
        resolveDevice: @escaping DeviceResolver = { DiskIdentityResolver.currentDevice(bsdName: $0) }
    ) {
        self.lifecycle = lifecycle
        self.resolveDevice = resolveDevice
    }

    @discardableResult
    func prepareForImaging(plan: CardImagingPlan) async throws -> StorageDevice {
        try plan.validateCurrentSource(resolveDevice(plan.sourceDevice.bsdName))
        try Task.checkCancellation()
        try await lifecycle.unmountWholeDisk(bsdName: plan.sourceDevice.bsdName)

        do {
            guard let currentDevice = resolveDevice(plan.sourceDevice.bsdName) else {
                throw CardImagingError.sourceDisconnected
            }
            try plan.validateCurrentSource(currentDevice)
            return currentDevice
        } catch {
            // If post-unmount validation fails, make a best effort to restore
            // the card before surfacing the identity or disconnection error.
            try? await lifecycle.mountWholeDisk(bsdName: plan.sourceDevice.bsdName)
            throw error
        }
    }

    func finishImaging(plan: CardImagingPlan, action: CardPostImagingAction) async throws {
        switch action {
        case .remount:
            try await lifecycle.mountWholeDisk(bsdName: plan.sourceDevice.bsdName)
        case .eject:
            try await lifecycle.ejectWholeDisk(bsdName: plan.sourceDevice.bsdName)
        }
    }
}
