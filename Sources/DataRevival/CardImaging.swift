import Foundation

struct CardImagingPlan: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case create
        case resume
    }

    let sourceDevice: StorageDevice
    let imageURL: URL
    let mapURL: URL
    let runnerLogURL: URL
    let resumeRecordURL: URL
    let resumeRecord: CardImagingResumeRecord
    let mapSnapshot: DDRescueMapSnapshot?
    let mode: Mode

    var sourceDeviceURL: URL {
        URL(fileURLWithPath: "/dev/r\(sourceDevice.bsdName)")
    }

    static func prepare(
        sourceDevice: StorageDevice,
        imageURL: URL,
        destinationWholeDiskBSDName: String?,
        availableCapacity: Int64?,
        fileManager: FileManager = .default
    ) throws -> CardImagingPlan {
        let image = imageURL.standardizedFileURL
        let map = image.appendingPathExtension("map")
        let runnerLog = image.appendingPathExtension("ddrescue.log")
        let resumeRecord = image.appendingPathExtension("datarevival.json")
        let parent = image.deletingLastPathComponent()

        let availableCapacity = try validateDestination(
            sourceDevice: sourceDevice,
            parent: parent,
            destinationWholeDiskBSDName: destinationWholeDiskBSDName,
            availableCapacity: availableCapacity,
            fileManager: fileManager
        )
        guard !fileSystemEntryExists(at: image, fileManager: fileManager),
              !fileSystemEntryExists(at: map, fileManager: fileManager),
              !fileSystemEntryExists(at: runnerLog, fileManager: fileManager),
              !fileSystemEntryExists(at: resumeRecord, fileManager: fileManager) else {
            throw CardImagingError.outputAlreadyExists
        }
        if availableCapacity < sourceDevice.byteCount {
            throw CardImagingError.insufficientSpace(
                required: sourceDevice.byteCount,
                available: availableCapacity
            )
        }

        return CardImagingPlan(
            sourceDevice: sourceDevice,
            imageURL: image,
            mapURL: map,
            runnerLogURL: runnerLog,
            resumeRecordURL: resumeRecord,
            resumeRecord: CardImagingResumeRecord(source: .init(device: sourceDevice)),
            mapSnapshot: nil,
            mode: .create
        )
    }

    static func prepareResume(
        sourceDevice: StorageDevice,
        imageURL: URL,
        destinationWholeDiskBSDName: String?,
        availableCapacity: Int64?,
        fileManager: FileManager = .default
    ) throws -> CardImagingPlan {
        let image = imageURL.standardizedFileURL
        let map = image.appendingPathExtension("map")
        let runnerLog = image.appendingPathExtension("ddrescue.log")
        let resumeRecordURL = image.appendingPathExtension("datarevival.json")
        let parent = image.deletingLastPathComponent()

        let availableCapacity = try validateDestination(
            sourceDevice: sourceDevice,
            parent: parent,
            destinationWholeDiskBSDName: destinationWholeDiskBSDName,
            availableCapacity: availableCapacity,
            fileManager: fileManager
        )

        guard let imageSizes = regularFileSizes(at: image, fileManager: fileManager),
              let mapSizes = regularFileSizes(at: map, fileManager: fileManager),
              mapSizes.logical > 0 else {
            throw CardImagingError.resumeFilesMissing
        }

        let mapSnapshot: DDRescueMapSnapshot
        do {
            mapSnapshot = try DDRescueMapfile.parse(
                Data(contentsOf: map),
                expectedByteCount: sourceDevice.byteCount
            )
        } catch {
            throw CardImagingError.resumeMapInvalid
        }

        let record: CardImagingResumeRecord
        do {
            let data = try Data(contentsOf: resumeRecordURL)
            record = try JSONDecoder().decode(CardImagingResumeRecord.self, from: data)
        } catch {
            throw CardImagingError.resumeMetadataInvalid
        }
        guard record.schemaVersion == CardImagingResumeRecord.currentSchemaVersion else {
            throw CardImagingError.resumeMetadataInvalid
        }
        guard record.source.matches(sourceDevice) else {
            throw CardImagingError.resumeSourceMismatch
        }

        guard imageSizes.logical <= sourceDevice.byteCount else {
            throw CardImagingError.resumeImageTooLarge
        }
        // ddrescue can create a sparse file whose logical size already equals the
        // source size. Count allocated bytes so resume planning still reserves
        // space for holes that have not been recovered yet.
        let existingAllocation = min(imageSizes.allocated, sourceDevice.byteCount)
        let remainingCapacity = sourceDevice.byteCount - existingAllocation
        if availableCapacity < remainingCapacity {
            throw CardImagingError.insufficientSpace(
                required: remainingCapacity,
                available: availableCapacity
            )
        }

        return CardImagingPlan(
            sourceDevice: sourceDevice,
            imageURL: image,
            mapURL: map,
            runnerLogURL: runnerLog,
            resumeRecordURL: resumeRecordURL,
            resumeRecord: record,
            mapSnapshot: mapSnapshot,
            mode: .resume
        )
    }

    private static func validateDestination(
        sourceDevice: StorageDevice,
        parent: URL,
        destinationWholeDiskBSDName: String?,
        availableCapacity: Int64?,
        fileManager: FileManager
    ) throws -> Int64 {
        guard sourceDevice.byteCount > 0 else {
            throw CardImagingError.sourceSizeUnknown
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: parent.path) else {
            throw CardImagingError.destinationIsNotWritable
        }
        guard let destinationWholeDiskBSDName else {
            throw CardImagingError.destinationDeviceUnknown
        }
        guard destinationWholeDiskBSDName != sourceDevice.bsdName else {
            throw CardImagingError.sourceDestinationCollision
        }
        guard let availableCapacity else {
            throw CardImagingError.destinationCapacityUnknown
        }
        return availableCapacity
    }

    private static func fileSystemEntryExists(at url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func regularFileSizes(
        at url: URL,
        fileManager: FileManager
    ) -> (logical: Int64, allocated: Int64)? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        let allocated = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        return (size.int64Value, max(0, allocated))
    }

    func validateCurrentSource(_ currentDevice: StorageDevice?) throws {
        guard let currentDevice else { throw CardImagingError.sourceDisconnected }
        guard sourceDevice.hasSameImagingIdentity(as: currentDevice) else {
            throw CardImagingError.sourceIdentityChanged
        }
    }
}

struct CardImagingResumeRecord: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    struct SourceIdentity: Codable, Sendable, Equatable {
        let bsdName: String
        let deviceGUID: Data?
        let byteCount: Int64
        let deviceModel: String?
        let connectionProtocol: String?

        init(device: StorageDevice) {
            bsdName = device.bsdName
            deviceGUID = device.deviceGUID
            byteCount = device.byteCount
            deviceModel = device.deviceModel
            connectionProtocol = device.connectionProtocol
        }

        func matches(_ device: StorageDevice) -> Bool {
            guard byteCount == device.byteCount,
                  deviceModel == device.deviceModel,
                  connectionProtocol == device.connectionProtocol else {
                return false
            }

            switch (deviceGUID, device.deviceGUID) {
            case let (.some(stored), .some(current)):
                return stored == current
            case (.none, .none):
                return bsdName == device.bsdName
            case (.some, .none), (.none, .some):
                return false
            }
        }
    }

    let schemaVersion: Int
    let source: SourceIdentity

    init(source: SourceIdentity) {
        schemaVersion = Self.currentSchemaVersion
        self.source = source
    }
}

enum CardImagingError: LocalizedError, Equatable {
    case sourceSizeUnknown
    case destinationIsNotWritable
    case destinationDeviceUnknown
    case destinationCapacityUnknown
    case sourceDestinationCollision
    case outputAlreadyExists
    case insufficientSpace(required: Int64, available: Int64)
    case sourceDisconnected
    case sourceIdentityChanged
    case resumeFilesMissing
    case resumeMapInvalid
    case resumeMetadataInvalid
    case resumeSourceMismatch
    case resumeImageTooLarge

    var errorDescription: String? {
        switch self {
        case .sourceSizeUnknown:
            "The size of the selected recovery source could not be determined."
        case .destinationIsNotWritable:
            "Choose a writable folder on the destination device."
        case .destinationDeviceUnknown:
            "The physical device containing the destination could not be identified."
        case .destinationCapacityUnknown:
            "The available space on the destination could not be determined."
        case .sourceDestinationCollision:
            "The card image must be saved on a different physical device from the recovery source."
        case .outputAlreadyExists:
            "The image or one of its sidecars already exists. Choose a new image name or validate it for resume."
        case let .insufficientSpace(required, available):
            "The destination has \(available.formatted(.byteCount(style: .file))) available, but the card image needs at least \(required.formatted(.byteCount(style: .file)))."
        case .sourceDisconnected:
            "The selected recovery source is no longer connected."
        case .sourceIdentityChanged:
            "The device at the selected path has changed. Select the recovery source again."
        case .resumeFilesMissing:
            "The existing card image and its nonempty ddrescue mapfile are both required to resume imaging."
        case .resumeMapInvalid:
            "The ddrescue mapfile is malformed or does not describe this entire recovery source."
        case .resumeMetadataInvalid:
            "The Data Revival resume record is missing, unreadable, or incompatible."
        case .resumeSourceMismatch:
            "The existing card image belongs to a different recovery source and cannot be resumed with this device."
        case .resumeImageTooLarge:
            "The existing card image is larger than the selected recovery source."
        }
    }
}

struct DDRescueCommand: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let runnerLogURL: URL
    let resumeRecordURL: URL?
    let resumeRecord: CardImagingResumeRecord?

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        runnerLogURL: URL,
        resumeRecordURL: URL? = nil,
        resumeRecord: CardImagingResumeRecord? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.runnerLogURL = runnerLogURL
        self.resumeRecordURL = resumeRecordURL
        self.resumeRecord = resumeRecord
    }

    static func image(executableURL: URL, plan: CardImagingPlan) -> DDRescueCommand {
        DDRescueCommand(
            executableURL: executableURL,
            arguments: [
                "--verbose",
                plan.sourceDeviceURL.path,
                plan.imageURL.path,
                plan.mapURL.path
            ],
            currentDirectoryURL: plan.imageURL.deletingLastPathComponent(),
            runnerLogURL: plan.runnerLogURL,
            resumeRecordURL: plan.resumeRecordURL,
            resumeRecord: plan.resumeRecord
        )
    }
}

enum DDRescueExecutableLocator {
    static func locate(fileManager: FileManager = .default) -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ddrescue"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/ddrescue",
            "/usr/local/bin/ddrescue",
            "/opt/local/bin/ddrescue"
        ]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }
}

final class DDRescueRunner: @unchecked Sendable {
    enum RunnerError: LocalizedError {
        case alreadyRunning
        case failedToCreateLog
        case failedToSaveResumeMetadata
        case unsuccessfulExit(Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "A card-imaging process is already running."
            case .failedToCreateLog:
                "The card-imaging process log could not be created."
            case .failedToSaveResumeMetadata:
                "The card-imaging resume record could not be saved."
            case let .unsuccessfulExit(status):
                "GNU ddrescue stopped with exit status \(status). Its image, mapfile, and log were preserved."
            }
        }
    }

    private let lock = NSLock()
    private var activeProcess: Process?

    func image(command: DDRescueCommand) async throws {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL

        try lock.withLock {
            guard activeProcess == nil else { throw RunnerError.alreadyRunning }
            activeProcess = process
        }

        defer {
            lock.withLock { activeProcess = nil }
        }

        try persistResumeMetadata(for: command)

        FileManager.default.createFile(atPath: command.runnerLogURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: command.runnerLogURL) else {
            throw RunnerError.failedToCreateLog
        }
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        defer {
            try? logHandle.close()
        }

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finishedProcess in
                    continuation.resume(returning: finishedProcess.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancel()
        }

        try Task.checkCancellation()
        guard status == 0 else { throw RunnerError.unsuccessfulExit(status) }
    }

    func cancel() {
        lock.withLock {
            guard let activeProcess, activeProcess.isRunning else { return }
            activeProcess.interrupt()
        }
    }

    private func persistResumeMetadata(for command: DDRescueCommand) throws {
        guard let url = command.resumeRecordURL,
              let record = command.resumeRecord else { return }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try JSONDecoder().decode(
                    CardImagingResumeRecord.self,
                    from: Data(contentsOf: url)
                )
                guard existing == record else {
                    throw RunnerError.failedToSaveResumeMetadata
                }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(record).write(to: url, options: .atomic)
            }
        } catch let error as RunnerError {
            throw error
        } catch {
            throw RunnerError.failedToSaveResumeMetadata
        }
    }
}
