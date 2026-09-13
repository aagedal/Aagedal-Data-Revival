import Combine
import Darwin
import Foundation
import Security

struct AuthopenInvocation: Sendable, Equatable {
    static let executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")

    let rawDeviceURL: URL

    var arguments: [String] {
        ["-stdoutpipe", "-extauth", rawDeviceURL.path]
    }

    var authorizationRight: String {
        "sys.openfile.readonly.\(rawDeviceURL.path)"
    }

    init(device: StorageDevice) {
        rawDeviceURL = URL(fileURLWithPath: "/dev/r\(device.bsdName)")
    }
}

enum AuthorizedImagingError: LocalizedError, Equatable {
    case authorizationFailed(Int32)
    case authopenUnavailable
    case authopenLaunchFailed(String)
    case authopenFailed(status: Int32, message: String?)
    case descriptorTransferFailed
    case invalidRawDevice
    case sourceIdentityChanged
    case imagingEngineUnavailable
    case imagingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(status):
            if status == errAuthorizationCanceled {
                "Administrator authorization was cancelled. No card data was read."
            } else if status == errAuthorizationDenied {
                "Administrator authorization was denied. No card data was read."
            } else {
                "Administrator authorization could not be completed (status \(status)). No card data was read."
            }
        case .authopenUnavailable:
            "macOS read-only device authorization is unavailable."
        case let .authopenLaunchFailed(message):
            "macOS read-only device authorization could not be started: \(message)"
        case let .authopenFailed(_, message):
            if let message, !message.isEmpty {
                "macOS did not open the card read-only: \(message)"
            } else {
                "macOS did not authorize read-only access to the card."
            }
        case .descriptorTransferFailed:
            "macOS did not return a usable read-only card handle."
        case .invalidRawDevice:
            "The authorized source is not the selected read-only raw card device."
        case .sourceIdentityChanged:
            "The device at the selected path changed before imaging began. Select the recovery source again."
        case .imagingEngineUnavailable:
            "The bundled GNU ddrescue imaging engine is unavailable."
        case let .imagingFailed(message):
            message
        }
    }
}

enum RawDeviceAuthorization {
    static func request(for invocation: AuthopenInvocation) throws -> Data {
        guard invocation.rawDeviceURL.path.range(
            of: #"^/dev/rdisk[0-9]+$"#,
            options: .regularExpression
        ) != nil else {
            throw AuthorizedImagingError.invalidRawDevice
        }
        var authorization: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw AuthorizedImagingError.authorizationFailed(status)
        }
        defer { AuthorizationFree(authorization, []) }

        status = invocation.authorizationRight.withCString { name in
            var item = AuthorizationItem(
                name: name,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil
                )
            }
        }
        guard status == errAuthorizationSuccess else {
            throw AuthorizedImagingError.authorizationFailed(status)
        }

        var externalForm = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(authorization, &externalForm)
        guard status == errAuthorizationSuccess else {
            throw AuthorizedImagingError.authorizationFailed(status)
        }
        return withUnsafeBytes(of: externalForm) { Data($0) }
    }
}

enum RawDeviceDescriptorValidator {
    static func validate(
        descriptor: Int32,
        rawDevicePath: String,
        expectedDevice: StorageDevice,
        resolveDevice: (String) -> StorageDevice?
    ) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY else {
            throw AuthorizedImagingError.invalidRawDevice
        }

        var openedInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_mode & S_IFMT == S_IFCHR,
              lstat(rawDevicePath, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFCHR,
              openedInfo.st_rdev == pathInfo.st_rdev else {
            throw AuthorizedImagingError.invalidRawDevice
        }

        guard let currentDevice = resolveDevice(expectedDevice.bsdName),
              expectedDevice.hasSameImagingIdentity(as: currentDevice) else {
            throw AuthorizedImagingError.sourceIdentityChanged
        }
    }
}

enum FileDescriptorReceiver {
    enum ReceiveError: Error {
        case failed
    }

    static func receive(from socket: Int32) throws -> Int32 {
        var payload: UInt8 = 0
        var control = [UInt8](
            repeating: 0,
            count: MemoryLayout<cmsghdr>.stride + MemoryLayout<Int32>.stride
        )
        var message = msghdr()

        let received = withUnsafeMutableBytes(of: &payload) { payloadBytes in
            var vector = iovec(iov_base: payloadBytes.baseAddress, iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                return control.withUnsafeMutableBytes { controlBytes in
                    message.msg_control = controlBytes.baseAddress
                    message.msg_controllen = socklen_t(controlBytes.count)
                    return recvmsg(socket, &message, 0)
                }
            }
        }
        guard received > 0,
              message.msg_flags & MSG_CTRUNC == 0,
              message.msg_controllen >= MemoryLayout<cmsghdr>.stride + MemoryLayout<Int32>.size else {
            throw ReceiveError.failed
        }

        return try control.withUnsafeBytes { controlBytes in
            guard let baseAddress = controlBytes.baseAddress else {
                throw ReceiveError.failed
            }
            let header = baseAddress.load(as: cmsghdr.self)
            guard header.cmsg_level == SOL_SOCKET,
                  header.cmsg_type == SCM_RIGHTS,
                  Int(header.cmsg_len) >= MemoryLayout<cmsghdr>.stride + MemoryLayout<Int32>.size else {
                throw ReceiveError.failed
            }
            return baseAddress
                .advanced(by: MemoryLayout<cmsghdr>.stride)
                .load(as: Int32.self)
        }
    }
}

protocol RawDeviceOpening: Sendable {
    func openReadOnly(
        device: StorageDevice,
        authorization: Data
    ) async throws -> FileHandle
    func cancel()
}

final class AuthopenRawDeviceOpener: RawDeviceOpening, @unchecked Sendable {
    typealias DeviceResolver = @Sendable (String) -> StorageDevice?

    private let executableURL: URL
    private let resolveDevice: DeviceResolver
    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancellationRequested = false

    init(
        executableURL: URL = AuthopenInvocation.executableURL,
        resolveDevice: @escaping DeviceResolver = {
            DiskIdentityResolver.currentDevice(bsdName: $0)
        }
    ) {
        self.executableURL = executableURL
        self.resolveDevice = resolveDevice
    }

    func openReadOnly(
        device: StorageDevice,
        authorization: Data
    ) async throws -> FileHandle {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try self.openSynchronously(device: device, authorization: authorization)
            }.value
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
            if let activeProcess, activeProcess.isRunning {
                activeProcess.interrupt()
            }
        }
    }

    private func openSynchronously(
        device: StorageDevice,
        authorization: Data
    ) throws -> FileHandle {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AuthorizedImagingError.authopenUnavailable
        }

        let invocation = AuthopenInvocation(device: device)
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw AuthorizedImagingError.descriptorTransferFailed
        }
        let receiverSocket = sockets[0]
        let senderSocket = sockets[1]
        var receiverIsOpen = true
        var senderIsOpen = true
        defer {
            if receiverIsOpen { close(receiverSocket) }
            if senderIsOpen { close(senderSocket) }
        }

        let authorizationPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = invocation.arguments
        process.standardInput = authorizationPipe
        process.standardOutput = FileHandle(
            fileDescriptor: senderSocket,
            closeOnDealloc: false
        )
        process.standardError = errorPipe

        try lock.withLock {
            guard activeProcess == nil else {
                throw DDRescueRunner.RunnerError.alreadyRunning
            }
            cancellationRequested = false
            activeProcess = process
            do {
                try process.run()
            } catch {
                activeProcess = nil
                throw AuthorizedImagingError.authopenLaunchFailed(error.localizedDescription)
            }
        }

        close(senderSocket)
        senderIsOpen = false
        do {
            try authorizationPipe.fileHandleForWriting.write(contentsOf: authorization)
            try authorizationPipe.fileHandleForWriting.close()
        } catch {
            process.interrupt()
        }

        let receivedDescriptor = try? FileDescriptorReceiver.receive(from: receiverSocket)
        close(receiverSocket)
        receiverIsOpen = false
        process.waitUntilExit()
        let errorData = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errorMessage = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wasCancelled = lock.withLock { () -> Bool in
            let result = cancellationRequested
            activeProcess = nil
            cancellationRequested = false
            return result
        }
        if wasCancelled {
            if let receivedDescriptor { close(receivedDescriptor) }
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            if let receivedDescriptor { close(receivedDescriptor) }
            throw AuthorizedImagingError.authopenFailed(
                status: process.terminationStatus,
                message: errorMessage.isEmpty ? nil : errorMessage
            )
        }
        guard let receivedDescriptor else {
            throw AuthorizedImagingError.descriptorTransferFailed
        }

        do {
            try RawDeviceDescriptorValidator.validate(
                descriptor: receivedDescriptor,
                rawDevicePath: invocation.rawDeviceURL.path,
                expectedDevice: device,
                resolveDevice: resolveDevice
            )
            return FileHandle(fileDescriptor: receivedDescriptor, closeOnDealloc: true)
        } catch {
            close(receivedDescriptor)
            throw error
        }
    }
}

struct AuthorizedImagingResult: Sendable, Equatable {
    let message: String?
}

final class AuthorizedCardImagingClient: @unchecked Sendable {
    private let opener: any RawDeviceOpening
    private let runner: DDRescueRunner

    init(
        opener: any RawDeviceOpening = AuthopenRawDeviceOpener(),
        runner: DDRescueRunner = DDRescueRunner()
    ) {
        self.opener = opener
        self.runner = runner
    }

    func image(
        plan: CardImagingPlan,
        authorization: Data,
        onProgress: (@Sendable (DDRescueMapSnapshot) async -> Void)? = nil
    ) async throws -> AuthorizedImagingResult {
        try plan.validateForExecution()
        guard let executableURL = DDRescueExecutableLocator.locate() else {
            throw AuthorizedImagingError.imagingEngineUnavailable
        }
        let sourceHandle = try await opener.openReadOnly(
            device: plan.sourceDevice,
            authorization: authorization
        )
        defer { try? sourceHandle.close() }

        let command = DDRescueCommand.image(
            executableURL: executableURL,
            plan: plan,
            sourcePath: "/dev/fd/0"
        )
        do {
            try await runner.image(
                command: command,
                sourceFileHandle: sourceHandle,
                onProgress: onProgress
            )
        } catch let error as DDRescueRunner.RunnerError {
            if case let .unsuccessfulExit(status) = error {
                throw AuthorizedImagingError.imagingFailed(
                    imagingFailureMessage(plan: plan, exitStatus: status)
                )
            }
            throw error
        }

        let snapshot = plan.mapURL.flatMapSnapshot(expectedByteCount: plan.sourceDevice.byteCount)
        let message: String? = if let snapshot, snapshot.badSectorByteCount > 0 {
            "GNU ddrescue finished, but the mapfile contains unreadable regions. Keep the mapfile with the image; another resume attempt may recover more data."
        } else {
            nil
        }
        return AuthorizedImagingResult(message: message)
    }

    func cancelActiveOperation() {
        opener.cancel()
        runner.cancel()
    }

    private func imagingFailureMessage(plan: CardImagingPlan, exitStatus: Int32) -> String {
        let log = ((try? String(contentsOf: plan.runnerLogURL, encoding: .utf8)) ?? "")
            .lowercased()
        if log.contains("no space left on device") ||
            log.contains("disk full") ||
            log.contains("not enough space") {
            return "The destination ran out of space while imaging. The partial image and resume files were preserved; free enough space, then check the existing image for resume."
        }
        if DiskIdentityResolver.currentDevice(bsdName: plan.sourceDevice.bsdName)?
            .hasSameImagingIdentity(as: plan.sourceDevice) != true ||
            log.contains("no such device") ||
            log.contains("device not configured") ||
            log.contains("input file disappeared") {
            return "The recovery source was removed or changed while imaging. The partial image and resume files were preserved; reconnect the original card, then check the existing image for resume."
        }
        if plan.mapURL.flatMapSnapshot(expectedByteCount: plan.sourceDevice.byteCount)?
            .badSectorByteCount ?? 0 > 0 ||
            log.contains("input/output error") ||
            log.contains("read error") ||
            log.contains("error reading") {
            return "GNU ddrescue stopped after encountering read errors. The partial image and mapfile were preserved; retrying the existing image may recover more data."
        }
        return "GNU ddrescue stopped with exit status \(exitStatus). The partial image, mapfile, and log were preserved for diagnosis and resume."
    }
}

private extension URL {
    func flatMapSnapshot(expectedByteCount: Int64) -> DDRescueMapSnapshot? {
        guard let data = try? Data(contentsOf: self) else { return nil }
        return try? DDRescueMapfile.parse(data, expectedByteCount: expectedByteCount)
    }
}

@MainActor
final class CardImagingViewModel: ObservableObject {
    private enum CancellationReason {
        case user
        case systemSleep
    }

    enum State: Equatable {
        case idle
        case preparing
        case imaging
        case cancelling
        case completed
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: DDRescueMapSnapshot?
    @Published private(set) var activePlan: CardImagingPlan?
    @Published private(set) var completionNotice: String?

    private let client: AuthorizedCardImagingClient
    private let sourceCoordinator: CardImagingSourceCoordinator
    private var imagingTask: Task<Void, Never>?
    private var cancellationReason: CancellationReason?

    init(
        client: AuthorizedCardImagingClient = AuthorizedCardImagingClient(),
        sourceCoordinator: CardImagingSourceCoordinator = CardImagingSourceCoordinator()
    ) {
        self.client = client
        self.sourceCoordinator = sourceCoordinator
    }

    var isActive: Bool {
        switch state {
        case .preparing, .imaging, .cancelling:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    func start(plan: CardImagingPlan) {
        guard !isActive else { return }
        state = .preparing
        progress = plan.mapSnapshot
        activePlan = plan
        completionNotice = nil
        cancellationReason = nil

        imagingTask = Task { [weak self] in
            guard let self else { return }
            var sourceWasUnmounted = false
            do {
                try plan.validateForExecution()
                let invocation = AuthopenInvocation(device: plan.sourceDevice)
                let authorization = try RawDeviceAuthorization.request(for: invocation)
                try await sourceCoordinator.prepareForImaging(plan: plan)
                sourceWasUnmounted = true
                state = .imaging

                let result = try await client.image(
                    plan: plan,
                    authorization: authorization
                ) { snapshot in
                    await MainActor.run { self.progress = snapshot }
                }
                if let snapshot = plan.mapURL.flatMapSnapshot(
                    expectedByteCount: plan.sourceDevice.byteCount
                ) {
                    progress = snapshot
                }
                completionNotice = result.message
                state = .completed
            } catch is CancellationError {
                if sourceWasUnmounted {
                    try? await sourceCoordinator.finishImaging(plan: plan, action: .remount)
                }
                if cancellationReason == .systemSleep {
                    state = .failed("Card imaging stopped because the Mac was going to sleep. The partial image and resume files were preserved; reconnect the card if needed, then check the existing image for resume.")
                } else {
                    state = .failed("Card imaging was cancelled. The partial image and its resume files were preserved and can be checked for resume.")
                }
                cancellationReason = nil
            } catch {
                if sourceWasUnmounted {
                    try? await sourceCoordinator.finishImaging(plan: plan, action: .remount)
                }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        cancellationReason = .user
        stopActiveImaging()
    }

    func interruptForSystemSleep() {
        guard isActive else { return }
        cancellationReason = .systemSleep
        stopActiveImaging()
    }

    private func stopActiveImaging() {
        state = .cancelling
        client.cancelActiveOperation()
        imagingTask?.cancel()
    }

    func finish(_ action: CardPostImagingAction) {
        guard state == .completed, let plan = activePlan else { return }
        imagingTask = Task {
            do {
                try await sourceCoordinator.finishImaging(plan: plan, action: action)
                state = .idle
                activePlan = nil
                progress = nil
                completionNotice = nil
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func clearFailure() {
        guard case .failed = state else { return }
        state = .idle
    }
}
