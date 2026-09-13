import Foundation
import Combine
import DiskArbitration
import Darwin

struct StorageDevice: Identifiable, Sendable, Equatable {
    let bsdName: String
    let mediaName: String?
    let deviceModel: String?
    let connectionProtocol: String?
    let deviceGUID: Data?
    let byteCount: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool

    var id: String { bsdName }
    var devicePath: String { "/dev/\(bsdName)" }

    var displayName: String {
        [mediaName, deviceModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? bsdName
    }

    var isRecoverySourceCandidate: Bool {
        !isInternal || isRemovable || isEjectable
    }

    /// Device names such as `disk7` can be reused after a disconnect. Imaging
    /// code uses this comparison immediately before opening the source so a
    /// replacement device is not mistaken for the one the user selected.
    func hasSameImagingIdentity(as other: StorageDevice) -> Bool {
        guard bsdName == other.bsdName,
              byteCount == other.byteCount,
              deviceModel == other.deviceModel,
              connectionProtocol == other.connectionProtocol else {
            return false
        }

        switch (deviceGUID, other.deviceGUID) {
        case let (.some(lhs), .some(rhs)):
            return lhs == rhs
        case (.none, .none):
            return true
        case (.some, .none), (.none, .some):
            return false
        }
    }

    init?(
        bsdName: String,
        description: [String: Any]
    ) {
        guard description[Self.mediaWholeKey] as? Bool == true else { return nil }

        self.bsdName = bsdName
        mediaName = description[Self.mediaNameKey] as? String
        deviceModel = description[Self.deviceModelKey] as? String
        connectionProtocol = description[Self.deviceProtocolKey] as? String
        deviceGUID = description[Self.deviceGUIDKey] as? Data
        byteCount = (description[Self.mediaSizeKey] as? NSNumber)?.int64Value ?? 0
        isInternal = description[Self.deviceInternalKey] as? Bool ?? true
        isRemovable = description[Self.mediaRemovableKey] as? Bool ?? false
        isEjectable = description[Self.mediaEjectableKey] as? Bool ?? false
    }

    fileprivate init?(disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk),
              let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return nil
        }
        self.init(bsdName: String(cString: bsdName), description: description)
    }

    private static let mediaWholeKey = kDADiskDescriptionMediaWholeKey as String
    private static let mediaNameKey = kDADiskDescriptionMediaNameKey as String
    private static let mediaSizeKey = kDADiskDescriptionMediaSizeKey as String
    private static let mediaRemovableKey = kDADiskDescriptionMediaRemovableKey as String
    private static let mediaEjectableKey = kDADiskDescriptionMediaEjectableKey as String
    private static let deviceInternalKey = kDADiskDescriptionDeviceInternalKey as String
    private static let deviceGUIDKey = kDADiskDescriptionDeviceGUIDKey as String
    private static let deviceModelKey = kDADiskDescriptionDeviceModelKey as String
    private static let deviceProtocolKey = kDADiskDescriptionDeviceProtocolKey as String
}

enum DiskIdentityResolver {
    static func currentDevice(
        bsdName: String,
        session: DASession? = DASessionCreate(kCFAllocatorDefault)
    ) -> StorageDevice? {
        guard let session,
              let disk = bsdName.withCString({
                  DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
              }) else {
            return nil
        }
        return StorageDevice(disk: disk)
    }

    static func wholeDiskBSDName(
        containing url: URL,
        session: DASession? = DASessionCreate(kCFAllocatorDefault)
    ) throws -> String? {
        guard let session else { return nil }
        let volumeURL = try volumeMountURL(containing: url)
        guard let volumeDisk = DADiskCreateFromVolumePath(
            kCFAllocatorDefault,
            session,
            volumeURL as CFURL
        ),
        let wholeDisk = DADiskCopyWholeDisk(volumeDisk),
        let bsdName = DADiskGetBSDName(wholeDisk) else {
            return nil
        }
        return String(cString: bsdName)
    }

    /// Disk Arbitration requires the volume's mount point, not an arbitrary
    /// descendant. `statfs` also handles APFS firmlinks such as `/Users` by
    /// returning the actual Data-volume mount.
    static func volumeMountURL(containing url: URL) throws -> URL {
        var fileSystem = statfs()
        guard statfs(url.path, &fileSystem) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let mountPath = withUnsafePointer(to: &fileSystem.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }
}

/// Disk Arbitration delivers callbacks on the main queue configured in `start()`.
/// SwiftUI also calls the public lifecycle methods on that queue.
final class DiskDeviceMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var devices: [StorageDevice] = []
    @Published private(set) var isMonitoring = false
    @Published private(set) var errorMessage: String?

    private var session: DASession?

    func start() {
        guard session == nil else { return }
        errorMessage = nil
        devices = []

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            errorMessage = "macOS disk discovery could not be started."
            return
        }

        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        let wholeMediaMatch = [kDADiskDescriptionMediaWholeKey as String: true] as CFDictionary
        DARegisterDiskAppearedCallback(session, wholeMediaMatch, diskAppeared, context)
        DARegisterDiskDisappearedCallback(session, wholeMediaMatch, diskDisappeared, context)
        DASessionSetDispatchQueue(session, .main)
        isMonitoring = true
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
        devices = []
        isMonitoring = false
    }

    fileprivate func add(_ disk: DADisk) {
        guard let device = StorageDevice(disk: disk), device.isRecoverySourceCandidate else { return }
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        devices.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    fileprivate func remove(_ disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk) else { return }
        let id = String(cString: bsdName)
        devices.removeAll { $0.id == id }
    }
}

private func diskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DiskDeviceMonitor>.fromOpaque(context).takeUnretainedValue().add(disk)
}

private func diskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DiskDeviceMonitor>.fromOpaque(context).takeUnretainedValue().remove(disk)
}
