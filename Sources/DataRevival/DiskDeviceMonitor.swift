import Foundation
import Combine
import DiskArbitration

struct StorageDevice: Identifiable, Sendable, Equatable {
    let bsdName: String
    let mediaName: String?
    let deviceModel: String?
    let connectionProtocol: String?
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

    init?(
        bsdName: String,
        description: [String: Any]
    ) {
        guard description[Self.mediaWholeKey] as? Bool == true else { return nil }

        self.bsdName = bsdName
        mediaName = description[Self.mediaNameKey] as? String
        deviceModel = description[Self.deviceModelKey] as? String
        connectionProtocol = description[Self.deviceProtocolKey] as? String
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
    private static let deviceModelKey = kDADiskDescriptionDeviceModelKey as String
    private static let deviceProtocolKey = kDADiskDescriptionDeviceProtocolKey as String
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
