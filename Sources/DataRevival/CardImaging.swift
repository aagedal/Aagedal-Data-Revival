import Foundation

struct CardImagingPlan: Sendable, Equatable {
    let sourceDevice: StorageDevice
    let imageURL: URL
    let mapURL: URL
    let runnerLogURL: URL

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
        let parent = image.deletingLastPathComponent()

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
        guard !fileSystemEntryExists(at: image, fileManager: fileManager),
              !fileSystemEntryExists(at: map, fileManager: fileManager),
              !fileSystemEntryExists(at: runnerLog, fileManager: fileManager) else {
            throw CardImagingError.outputAlreadyExists
        }
        guard let availableCapacity else {
            throw CardImagingError.destinationCapacityUnknown
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
            runnerLogURL: runnerLog
        )
    }

    private static func fileSystemEntryExists(at url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    func validateCurrentSource(_ currentDevice: StorageDevice?) throws {
        guard let currentDevice else { throw CardImagingError.sourceDisconnected }
        guard sourceDevice.hasSameImagingIdentity(as: currentDevice) else {
            throw CardImagingError.sourceIdentityChanged
        }
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
            "The image, mapfile, or process log already exists. Choose a new image name."
        case let .insufficientSpace(required, available):
            "The destination has \(available.formatted(.byteCount(style: .file))) available, but the card image needs at least \(required.formatted(.byteCount(style: .file)))."
        case .sourceDisconnected:
            "The selected recovery source is no longer connected."
        case .sourceIdentityChanged:
            "The device at the selected path has changed. Select the recovery source again."
        }
    }
}

struct DDRescueCommand: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let runnerLogURL: URL

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
            runnerLogURL: plan.runnerLogURL
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
        case unsuccessfulExit(Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "A card-imaging process is already running."
            case .failedToCreateLog:
                "The card-imaging process log could not be created."
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

        FileManager.default.createFile(atPath: command.runnerLogURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: command.runnerLogURL) else {
            throw RunnerError.failedToCreateLog
        }
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
}
