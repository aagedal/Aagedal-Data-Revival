import DiskArbitration
import Foundation
import Security

private enum HelperConstants {
    static let machServiceName = "com.aagedal.DataRevival.ImagingHelper"
    static let appCodeSigningRequirement = "anchor apple generic and identifier \"com.aagedal.DataRevival\" and certificate leaf[subject.OU] = \"3R5QGG9DW6\""
    static let helperVersion = 1
}

@objc private protocol ImagingHelperXPCProtocol {
    func helperVersion(reply: @escaping (Int) -> Void)
    func startImaging(
        request: Data,
        authorization: Data,
        reply: @escaping (Data) -> Void
    )
    func cancelImaging(operationIdentifier: String, reply: @escaping (Bool) -> Void)
}

private struct ImagingRequest: Codable {
    static let currentSchemaVersion = 1

    enum Mode: String, Codable {
        case create
        case resume
    }

    struct Source: Codable {
        let bsdName: String
        let deviceGUID: Data?
        let byteCount: Int64
        let deviceModel: String?
        let connectionProtocol: String?
    }

    let schemaVersion: Int
    let operationIdentifier: UUID
    let source: Source
    let imagePath: String
    let mapPath: String
    let runnerLogPath: String
    let resumeRecordPath: String
    let mode: Mode
}

private struct ResumeRecord: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let source: ImagingRequest.Source
}

private struct ImagingResponse: Codable {
    enum Outcome: String, Codable {
        case completed
        case cancelled
        case failed
    }

    let outcome: Outcome
    let exitStatus: Int32?
    let message: String?
    let issue: ImagingIssue?
}

private enum ImagingIssue: String, Codable {
    case authorizationDenied
    case sourceRemoved
    case destinationFull
    case readErrors
    case helperFailure
}

private enum HelperError: LocalizedError {
    case notPrivileged
    case unauthorized(OSStatus)
    case incompatibleRequest
    case invalidSource
    case sourceChanged
    case sourceNotRawDevice
    case invalidDestination
    case sourceDestinationCollision
    case outputStateChanged
    case engineUnavailable
    case alreadyRunning
    case unableToCreateLog
    case processLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPrivileged:
            "The imaging helper is not running with system privileges."
        case let .unauthorized(status):
            "Administrator authorization could not be verified (status \(status))."
        case .incompatibleRequest:
            "The imaging request format is incompatible with this helper."
        case .invalidSource:
            "The recovery source path is invalid."
        case .sourceChanged:
            "The recovery source identity changed before the raw device was opened."
        case .sourceNotRawDevice:
            "The selected recovery source is not a raw device."
        case .invalidDestination:
            "The card-image destination is invalid."
        case .sourceDestinationCollision:
            "The card image cannot be written to the recovery source device."
        case .outputStateChanged:
            "The image or one of its sidecars changed after the imaging plan was approved."
        case .engineUnavailable:
            "The bundled GNU ddrescue executable is unavailable."
        case .alreadyRunning:
            "The helper is already imaging another card."
        case .unableToCreateLog:
            "The ddrescue log could not be opened."
        case let .processLaunchFailed(message):
            "GNU ddrescue could not be started: \(message)"
        }
    }
}

private struct ResolvedDevice {
    let bsdName: String
    let deviceGUID: Data?
    let byteCount: Int64
    let deviceModel: String?
    let connectionProtocol: String?

    func matches(_ expected: ImagingRequest.Source) -> Bool {
        guard bsdName == expected.bsdName,
              byteCount == expected.byteCount,
              deviceModel == expected.deviceModel,
              connectionProtocol == expected.connectionProtocol else {
            return false
        }
        switch (deviceGUID, expected.deviceGUID) {
        case let (.some(current), .some(stored)):
            return current == stored
        case (.none, .none):
            return true
        case (.some, .none), (.none, .some):
            return false
        }
    }
}

private enum DeviceResolver {
    static func currentDevice(bsdName: String) -> ResolvedDevice? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = bsdName.withCString({
                  DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
              }),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              description[kDADiskDescriptionMediaWholeKey as String] as? Bool == true else {
            return nil
        }
        return ResolvedDevice(
            bsdName: bsdName,
            deviceGUID: description[kDADiskDescriptionDeviceGUIDKey as String] as? Data,
            byteCount: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0,
            deviceModel: description[kDADiskDescriptionDeviceModelKey as String] as? String,
            connectionProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        )
    }

    static func wholeDiskBSDName(containing directory: URL) throws -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        let values = try directory.resourceValues(forKeys: [.volumeURLForRemountingKey])
        let volumeURL = values.volumeURLForRemounting ?? directory
        guard let disk = DADiskCreateFromVolumePath(
            kCFAllocatorDefault,
            session,
            volumeURL as CFURL
        ),
        let wholeDisk = DADiskCopyWholeDisk(disk),
        let name = DADiskGetBSDName(wholeDisk) else {
            return nil
        }
        return String(cString: name)
    }
}

private final class ImagingOperationRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aagedal.DataRevival.ImagingHelper.operation")
    private let lock = NSLock()
    private var activeProcess: Process?
    private var activeIdentifier: UUID?
    private var activeCancellationRequested = false
    private var cancelledIdentifiers: Set<UUID> = []

    func start(
        requestData: Data,
        authorizationData: Data,
        clientUID: uid_t,
        clientGID: gid_t,
        completion: @escaping @Sendable (ImagingResponse) -> Void
    ) {
        queue.async {
            do {
                guard geteuid() == 0 else { throw HelperError.notPrivileged }
                try Self.verifyAuthorization(authorizationData)
                let request = try JSONDecoder().decode(ImagingRequest.self, from: requestData)
                let prepared = try Self.prepare(request: request)

                let process = Process()
                process.executableURL = prepared.executableURL
                process.arguments = [
                    "--verbose",
                    "/dev/fd/0",
                    request.imagePath,
                    request.mapPath
                ]
                process.currentDirectoryURL = prepared.destinationDirectory
                process.standardInput = FileHandle(
                    fileDescriptor: prepared.sourceDescriptor,
                    closeOnDealloc: false
                )
                process.standardOutput = prepared.logHandle
                process.standardError = prepared.logHandle

                defer {
                    self.lock.withLock {
                        if self.activeIdentifier == request.operationIdentifier {
                            self.activeProcess = nil
                            self.activeIdentifier = nil
                            self.activeCancellationRequested = false
                        }
                    }
                    try? prepared.logHandle.close()
                    close(prepared.sourceDescriptor)
                    Self.restoreOwnership(request: request, uid: clientUID, gid: clientGID)
                }

                try self.lock.withLock {
                    guard self.activeProcess == nil else { throw HelperError.alreadyRunning }
                    if self.cancelledIdentifiers.remove(request.operationIdentifier) != nil {
                        throw CancellationError()
                    }
                    self.activeProcess = process
                    self.activeIdentifier = request.operationIdentifier
                    self.activeCancellationRequested = false
                    do {
                        try process.run()
                    } catch {
                        throw HelperError.processLaunchFailed(error.localizedDescription)
                    }
                }
                process.waitUntilExit()

                let wasCancelled = self.lock.withLock {
                    self.activeIdentifier == request.operationIdentifier &&
                    self.activeCancellationRequested
                }
                if wasCancelled {
                    completion(ImagingResponse(
                        outcome: .cancelled,
                        exitStatus: process.terminationStatus,
                        message: nil,
                        issue: nil
                    ))
                } else if process.terminationStatus == 0 {
                    if Self.mapfileContainsBadSectors(at: request.mapPath) {
                        completion(ImagingResponse(
                            outcome: .completed,
                            exitStatus: 0,
                            message: "GNU ddrescue finished, but the mapfile contains unreadable regions. Keep the mapfile with the image; another resume attempt may recover more data.",
                            issue: .readErrors
                        ))
                    } else {
                        completion(ImagingResponse(
                            outcome: .completed,
                            exitStatus: 0,
                            message: nil,
                            issue: nil
                        ))
                    }
                } else {
                    let failure = Self.classifyProcessFailure(
                        request: request,
                        exitStatus: process.terminationStatus
                    )
                    completion(ImagingResponse(
                        outcome: .failed,
                        exitStatus: process.terminationStatus,
                        message: failure.message,
                        issue: failure.issue
                    ))
                }
            } catch is CancellationError {
                completion(ImagingResponse(
                    outcome: .cancelled,
                    exitStatus: nil,
                    message: nil,
                    issue: nil
                ))
            } catch {
                let issue: ImagingIssue
                switch error as? HelperError {
                case .unauthorized:
                    issue = .authorizationDenied
                case .sourceChanged, .invalidSource, .sourceNotRawDevice:
                    issue = .sourceRemoved
                case nil, .some:
                    issue = .helperFailure
                }
                completion(ImagingResponse(
                    outcome: .failed,
                    exitStatus: nil,
                    message: error.localizedDescription,
                    issue: issue
                ))
            }
        }
    }

    func cancel(operationIdentifier: String) -> Bool {
        guard let identifier = UUID(uuidString: operationIdentifier) else { return false }
        return lock.withLock {
            guard activeIdentifier == identifier, let activeProcess else {
                cancelledIdentifiers.insert(identifier)
                if cancelledIdentifiers.count > 16 {
                    cancelledIdentifiers.remove(cancelledIdentifiers.first!)
                }
                return true
            }
            activeCancellationRequested = true
            if activeProcess.isRunning {
                activeProcess.interrupt()
            }
            return true
        }
    }

    private struct PreparedOperation {
        let executableURL: URL
        let destinationDirectory: URL
        let sourceDescriptor: Int32
        let logHandle: FileHandle
    }

    private static func prepare(request: ImagingRequest) throws -> PreparedOperation {
        try validateStructure(request)

        guard let current = DeviceResolver.currentDevice(bsdName: request.source.bsdName),
              current.matches(request.source) else {
            throw HelperError.sourceChanged
        }

        let image = URL(fileURLWithPath: request.imagePath)
        let destinationDirectory = image.deletingLastPathComponent()
        guard destinationDirectory.resolvingSymlinksInPath() == destinationDirectory,
              let destinationDisk = try DeviceResolver.wholeDiskBSDName(
                containing: destinationDirectory
              ) else {
            throw HelperError.invalidDestination
        }
        guard destinationDisk != request.source.bsdName else {
            throw HelperError.sourceDestinationCollision
        }
        try validateOutputState(request)

        let sourcePath = "/dev/r\(request.source.bsdName)"
        let sourceDescriptor = open(sourcePath, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw HelperError.invalidSource }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFCHR else {
            close(sourceDescriptor)
            throw HelperError.sourceNotRawDevice
        }

        // Re-resolve after the privileged read-only open. ddrescue receives this
        // already-open descriptor through /dev/fd, so a later BSD-name reuse
        // cannot redirect the operation to a replacement device.
        guard let openedDevice = DeviceResolver.currentDevice(bsdName: request.source.bsdName),
              openedDevice.matches(request.source) else {
            close(sourceDescriptor)
            throw HelperError.sourceChanged
        }

        let executableURL = helperExecutableURL()
        var executableIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: executableURL.path,
            isDirectory: &executableIsDirectory
        ),
        !executableIsDirectory.boolValue,
        FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            close(sourceDescriptor)
            throw HelperError.engineUnavailable
        }

        if !FileManager.default.fileExists(atPath: request.runnerLogPath) {
            FileManager.default.createFile(atPath: request.runnerLogPath, contents: nil)
        }
        guard let logHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: request.runnerLogPath)) else {
            close(sourceDescriptor)
            throw HelperError.unableToCreateLog
        }
        try logHandle.seekToEnd()

        return PreparedOperation(
            executableURL: executableURL,
            destinationDirectory: destinationDirectory,
            sourceDescriptor: sourceDescriptor,
            logHandle: logHandle
        )
    }

    private static func validateStructure(_ request: ImagingRequest) throws {
        guard request.schemaVersion == ImagingRequest.currentSchemaVersion else {
            throw HelperError.incompatibleRequest
        }
        guard request.source.byteCount > 0,
              request.source.bsdName.range(
                of: #"^disk[0-9]+$"#,
                options: .regularExpression
              ) != nil else {
            throw HelperError.invalidSource
        }
        let image = URL(fileURLWithPath: request.imagePath).standardizedFileURL
        guard image.path == request.imagePath,
              image.path.hasPrefix("/"),
              image.appendingPathExtension("map").path == request.mapPath,
              image.appendingPathExtension("ddrescue.log").path == request.runnerLogPath,
              image.appendingPathExtension("datarevival.json").path == request.resumeRecordPath else {
            throw HelperError.invalidDestination
        }
    }

    private static func validateOutputState(_ request: ImagingRequest) throws {
        let manager = FileManager.default
        let image = URL(fileURLWithPath: request.imagePath)
        let map = URL(fileURLWithPath: request.mapPath)
        let log = URL(fileURLWithPath: request.runnerLogPath)
        let record = URL(fileURLWithPath: request.resumeRecordPath)
        let allURLs = [image, map, log, record]

        for url in allURLs where manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw HelperError.outputStateChanged
            }
        }

        guard manager.fileExists(atPath: record.path) else {
            throw HelperError.outputStateChanged
        }
        guard let recordData = try? Data(contentsOf: record),
              let storedRecord = try? JSONDecoder().decode(ResumeRecord.self, from: recordData),
              storedRecord.schemaVersion == ResumeRecord.currentSchemaVersion,
              sourceMatches(storedRecord.source, request.source) else {
            throw HelperError.outputStateChanged
        }

        var fileIdentities: Set<FileIdentity> = []
        for url in allURLs where manager.fileExists(atPath: url.path) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw HelperError.outputStateChanged }
            let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
            guard fileIdentities.insert(identity).inserted else {
                throw HelperError.outputStateChanged
            }
        }
        switch request.mode {
        case .create:
            guard !manager.fileExists(atPath: image.path),
                  !manager.fileExists(atPath: map.path) else {
                throw HelperError.outputStateChanged
            }
        case .resume:
            guard manager.fileExists(atPath: image.path),
                  manager.fileExists(atPath: map.path) else {
                throw HelperError.outputStateChanged
            }
        }
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func sourceMatches(
        _ lhs: ImagingRequest.Source,
        _ rhs: ImagingRequest.Source
    ) -> Bool {
        guard lhs.byteCount == rhs.byteCount,
              lhs.deviceModel == rhs.deviceModel,
              lhs.connectionProtocol == rhs.connectionProtocol else {
            return false
        }
        switch (lhs.deviceGUID, rhs.deviceGUID) {
        case let (.some(stored), .some(current)):
            return stored == current
        case (.none, .none):
            return lhs.bsdName == rhs.bsdName
        case (.some, .none), (.none, .some):
            return false
        }
    }

    private static func verifyAuthorization(_ data: Data) throws {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw HelperError.unauthorized(errAuthorizationInvalidRef)
        }
        var externalForm = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &externalForm) { destination in
            data.copyBytes(to: destination)
        }
        var authorization: AuthorizationRef?
        var status = AuthorizationCreateFromExternalForm(&externalForm, &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw HelperError.unauthorized(status)
        }
        defer { AuthorizationFree(authorization, []) }

        status = "system.privilege.admin".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil, [.extendRights], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            throw HelperError.unauthorized(status)
        }
    }

    private static func helperExecutableURL() -> URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ddrescue")
            .standardizedFileURL
    }

    private static func restoreOwnership(request: ImagingRequest, uid: uid_t, gid: gid_t) {
        for path in [request.imagePath, request.mapPath, request.runnerLogPath, request.resumeRecordPath] {
            if FileManager.default.fileExists(atPath: path) {
                _ = chown(path, uid, gid)
            }
        }
    }

    private static func classifyProcessFailure(
        request: ImagingRequest,
        exitStatus: Int32
    ) -> (issue: ImagingIssue, message: String) {
        let log = logTail(at: request.runnerLogPath).lowercased()
        if log.contains("no space left on device") ||
            log.contains("disk full") ||
            log.contains("not enough space") {
            return (
                .destinationFull,
                "The destination ran out of space while imaging. The partial image and resume files were preserved; free enough space, then check the existing image for resume."
            )
        }

        let currentSource = DeviceResolver.currentDevice(bsdName: request.source.bsdName)
        if currentSource?.matches(request.source) != true ||
            log.contains("no such device") ||
            log.contains("device not configured") ||
            log.contains("input file disappeared") {
            return (
                .sourceRemoved,
                "The recovery source was removed or changed while imaging. The partial image and resume files were preserved; reconnect the original card, then check the existing image for resume."
            )
        }

        if mapfileContainsBadSectors(at: request.mapPath) ||
            log.contains("input/output error") ||
            log.contains("read error") ||
            log.contains("error reading") {
            return (
                .readErrors,
                "GNU ddrescue stopped after encountering read errors. The partial image and mapfile were preserved; retrying the existing image may recover more data."
            )
        }

        return (
            .helperFailure,
            "The privileged imaging helper stopped GNU ddrescue with exit status \(exitStatus). The partial image, mapfile, and logs were preserved for diagnosis and resume."
        )
    }

    private static func logTail(at path: String, maximumByteCount: Int = 64 * 1_024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return ""
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > UInt64(maximumByteCount) {
            try? handle.seek(toOffset: end - UInt64(maximumByteCount))
        } else {
            try? handle.seek(toOffset: 0)
        }
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private static func mapfileContainsBadSectors(at path: String) -> Bool {
        guard let contents = try? String(
            contentsOf: URL(fileURLWithPath: path),
            encoding: .utf8
        ) else {
            return false
        }
        var foundStatusLine = false
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: \.isWhitespace)
            guard !trimmed.isEmpty, trimmed.first != "#" else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3 else { continue }
            if !foundStatusLine {
                foundStatusLine = true
                continue
            }
            if fields[2] == "-" {
                return true
            }
        }
        return false
    }
}

private final class ImagingHelperSession: NSObject, ImagingHelperXPCProtocol {
    private let registry: ImagingOperationRegistry
    private let clientUID: uid_t
    private let clientGID: gid_t

    init(registry: ImagingOperationRegistry, connection: NSXPCConnection) {
        self.registry = registry
        clientUID = connection.effectiveUserIdentifier
        clientGID = connection.effectiveGroupIdentifier
    }

    func helperVersion(reply: @escaping (Int) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    func startImaging(
        request: Data,
        authorization: Data,
        reply: @escaping (Data) -> Void
    ) {
        let replyBox = XPCDataReply(reply)
        registry.start(
            requestData: request,
            authorizationData: authorization,
            clientUID: clientUID,
            clientGID: clientGID
        ) { response in
            let data = (try? JSONEncoder().encode(response)) ?? Data()
            replyBox.send(data)
        }
    }

    func cancelImaging(operationIdentifier: String, reply: @escaping (Bool) -> Void) {
        reply(registry.cancel(operationIdentifier: operationIdentifier))
    }
}

private final class XPCDataReply: @unchecked Sendable {
    private let body: (Data) -> Void

    init(_ body: @escaping (Data) -> Void) {
        self.body = body
    }

    func send(_ data: Data) {
        body(data)
    }
}

private final class ImagingHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let registry = ImagingOperationRegistry()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.setCodeSigningRequirement(HelperConstants.appCodeSigningRequirement)
        connection.exportedInterface = NSXPCInterface(with: ImagingHelperXPCProtocol.self)
        connection.exportedObject = ImagingHelperSession(
            registry: registry,
            connection: connection
        )
        connection.resume()
        return true
    }
}

private let delegate = ImagingHelperListenerDelegate()
private let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
