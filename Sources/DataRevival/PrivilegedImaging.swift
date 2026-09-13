import Combine
import Foundation
import Security
import ServiceManagement

enum PrivilegedImagingConstants {
    static let helperPlistName = "com.aagedal.DataRevival.ImagingHelper.plist"
    static let machServiceName = "com.aagedal.DataRevival.ImagingHelper"
    static let helperVersion = 1
    static let appCodeSigningRequirement = "anchor apple generic and identifier \"com.aagedal.DataRevival\" and certificate leaf[subject.OU] = \"3R5QGG9DW6\""
    static let helperCodeSigningRequirement = "anchor apple generic and identifier \"com.aagedal.DataRevival.ImagingHelper\" and certificate leaf[subject.OU] = \"3R5QGG9DW6\""
}

@objc protocol PrivilegedImagingXPCProtocol {
    func helperVersion(reply: @escaping (Int) -> Void)
    func startImaging(
        request: Data,
        authorization: Data,
        reply: @escaping (Data) -> Void
    )
    func cancelImaging(operationIdentifier: String, reply: @escaping (Bool) -> Void)
}

struct PrivilegedImagingRequest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    enum Mode: String, Codable, Sendable {
        case create
        case resume
    }

    struct Source: Codable, Sendable, Equatable {
        let bsdName: String
        let deviceGUID: Data?
        let byteCount: Int64
        let deviceModel: String?
        let connectionProtocol: String?

        init(_ device: StorageDevice) {
            bsdName = device.bsdName
            deviceGUID = device.deviceGUID
            byteCount = device.byteCount
            deviceModel = device.deviceModel
            connectionProtocol = device.connectionProtocol
        }
    }

    let schemaVersion: Int
    let operationIdentifier: UUID
    let source: Source
    let imagePath: String
    let mapPath: String
    let runnerLogPath: String
    let resumeRecordPath: String
    let mode: Mode

    init(plan: CardImagingPlan, operationIdentifier: UUID = UUID()) {
        schemaVersion = Self.currentSchemaVersion
        self.operationIdentifier = operationIdentifier
        source = Source(plan.sourceDevice)
        imagePath = plan.imageURL.path
        mapPath = plan.mapURL.path
        runnerLogPath = plan.runnerLogURL.path
        resumeRecordPath = plan.resumeRecordURL.path
        mode = plan.mode == .create ? .create : .resume
    }

    func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PrivilegedImagingError.incompatibleRequest
        }
        guard source.byteCount > 0,
              source.bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw PrivilegedImagingError.invalidSource
        }

        let image = URL(fileURLWithPath: imagePath).standardizedFileURL
        guard image.path == imagePath,
              image.isFileURL,
              image.path.hasPrefix("/"),
              image.appendingPathExtension("map").path == mapPath,
              image.appendingPathExtension("ddrescue.log").path == runnerLogPath,
              image.appendingPathExtension("datarevival.json").path == resumeRecordPath else {
            throw PrivilegedImagingError.invalidDestination
        }
    }
}

struct PrivilegedImagingResponse: Codable, Sendable, Equatable {
    enum Outcome: String, Codable, Sendable {
        case completed
        case cancelled
        case failed
    }

    let outcome: Outcome
    let exitStatus: Int32?
    let message: String?
    let issue: PrivilegedImagingIssue?
}

enum PrivilegedImagingIssue: String, Codable, Sendable, Equatable {
    case authorizationDenied
    case sourceRemoved
    case destinationFull
    case readErrors
    case helperFailure

    var fallbackMessage: String {
        switch self {
        case .authorizationDenied:
            "Administrator authorization was denied. No card data was read."
        case .sourceRemoved:
            "The recovery source was removed or changed. Reconnect the original card, then check the existing image for resume."
        case .destinationFull:
            "The destination ran out of space. Free enough space, then check the existing image for resume."
        case .readErrors:
            "The card contains unreadable regions. Keep the mapfile with the image so another resume attempt can retry them."
        case .helperFailure:
            "The privileged imaging helper stopped unexpectedly. The image, mapfile, and logs were preserved where possible."
        }
    }
}

struct PrivilegedImagingResult: Sendable, Equatable {
    let issue: PrivilegedImagingIssue?
    let message: String?
}

enum PrivilegedImagingError: LocalizedError, Equatable {
    case helperNotInstalled
    case helperNeedsApproval
    case helperUnavailable
    case incompatibleHelper
    case incompatibleRequest
    case invalidSource
    case invalidDestination
    case authorizationFailed(Int32)
    case invalidResponse
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            "Install the Data Revival imaging helper before starting card imaging."
        case .helperNeedsApproval:
            "Approve the Data Revival imaging helper in System Settings, then try again."
        case .helperUnavailable:
            "The privileged imaging helper could not be reached."
        case .incompatibleHelper:
            "The installed imaging helper is incompatible with this version of Data Revival."
        case .incompatibleRequest:
            "The imaging request format is incompatible with this version of Data Revival."
        case .invalidSource:
            "The privileged helper rejected the recovery source."
        case .invalidDestination:
            "The privileged helper rejected the card-image destination."
        case let .authorizationFailed(status):
            if status == errAuthorizationCanceled {
                "Administrator authorization was cancelled. No card data was read."
            } else if status == errAuthorizationDenied {
                "Administrator authorization was denied. No card data was read."
            } else {
                "Administrator authorization could not be completed (status \(status)). No card data was read."
            }
        case .invalidResponse:
            "The privileged imaging helper returned an unreadable response."
        case let .failed(message):
            message
        }
    }
}

enum PrivilegedImagingAuthorization {
    static func request() throws -> Data {
        var authorization: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw PrivilegedImagingError.authorizationFailed(status)
        }
        defer { AuthorizationFree(authorization, []) }

        let rightName = "system.privilege.admin"
        status = rightName.withCString { name in
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
            throw PrivilegedImagingError.authorizationFailed(status)
        }

        var externalForm = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(authorization, &externalForm)
        guard status == errAuthorizationSuccess else {
            throw PrivilegedImagingError.authorizationFailed(status)
        }
        return withUnsafeBytes(of: externalForm) { Data($0) }
    }
}

final class PrivilegedImagingClient: @unchecked Sendable {
    private let lock = NSLock()
    private var activeConnection: NSXPCConnection?
    private var activeOperationIdentifier: UUID?

    var serviceStatus: SMAppService.Status {
        SMAppService.daemon(plistName: PrivilegedImagingConstants.helperPlistName).status
    }

    func registerHelper() throws {
        try SMAppService.daemon(plistName: PrivilegedImagingConstants.helperPlistName).register()
    }

    static func openHelperApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func image(
        request: PrivilegedImagingRequest,
        authorization: Data,
        onProgress: (@Sendable (DDRescueMapSnapshot) async -> Void)? = nil
    ) async throws -> PrivilegedImagingResult {
        try request.validateStructure()
        switch serviceStatus {
        case .enabled:
            break
        case .requiresApproval:
            throw PrivilegedImagingError.helperNeedsApproval
        case .notRegistered, .notFound:
            throw PrivilegedImagingError.helperNotInstalled
        @unknown default:
            throw PrivilegedImagingError.helperUnavailable
        }

        let connection = makeConnection()
        lock.withLock {
            activeConnection = connection
            activeOperationIdentifier = request.operationIdentifier
        }
        defer {
            lock.withLock {
                activeConnection = nil
                activeOperationIdentifier = nil
            }
            connection.invalidate()
        }

        let version = try await helperVersion(using: connection)
        guard version == PrivilegedImagingConstants.helperVersion else {
            throw PrivilegedImagingError.incompatibleHelper
        }

        let progressTask = Task {
            guard let onProgress else { return }
            let mapURL = URL(fileURLWithPath: request.mapPath)
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: mapURL),
                   let snapshot = try? DDRescueMapfile.parse(
                    data,
                    expectedByteCount: request.source.byteCount
                   ) {
                    await onProgress(snapshot)
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        defer { progressTask.cancel() }

        let requestData = try JSONEncoder().encode(request)
        let responseData = try await withTaskCancellationHandler {
            try await invokeStart(
                requestData: requestData,
                authorization: authorization,
                connection: connection
            )
        } onCancel: {
            self.cancelActiveOperation()
        }
        let response = try JSONDecoder().decode(
            PrivilegedImagingResponse.self,
            from: responseData
        )
        switch response.outcome {
        case .completed:
            return PrivilegedImagingResult(
                issue: response.issue,
                message: response.message ?? response.issue?.fallbackMessage
            )
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw PrivilegedImagingError.failed(
                response.message ?? response.issue?.fallbackMessage ??
                    "The privileged imaging helper stopped unexpectedly."
            )
        }
    }

    func cancelActiveOperation() {
        let active = lock.withLock { (activeConnection, activeOperationIdentifier) }
        guard let connection = active.0, let identifier = active.1 else { return }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? PrivilegedImagingXPCProtocol else { return }
        proxy.cancelImaging(operationIdentifier: identifier.uuidString) { _ in }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: PrivilegedImagingConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: PrivilegedImagingXPCProtocol.self
        )
        connection.setCodeSigningRequirement(
            PrivilegedImagingConstants.helperCodeSigningRequirement
        )
        connection.resume()
        return connection
    }

    private func helperVersion(using connection: NSXPCConnection) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.resume(throwing: PrivilegedImagingError.helperUnavailable)
            }) as? PrivilegedImagingXPCProtocol else {
                gate.resume(throwing: PrivilegedImagingError.helperUnavailable)
                return
            }
            proxy.helperVersion { version in gate.resume(returning: version) }
        }
    }

    private func invokeStart(
        requestData: Data,
        authorization: Data,
        connection: NSXPCConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.resume(throwing: PrivilegedImagingError.helperUnavailable)
            }) as? PrivilegedImagingXPCProtocol else {
                gate.resume(throwing: PrivilegedImagingError.helperUnavailable)
                return
            }
            proxy.startImaging(request: requestData, authorization: authorization) { data in
                gate.resume(returning: data)
            }
        }
    }
}

private final class XPCReplyGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func resume(throwing error: Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
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
    @Published private(set) var helperStatus: SMAppService.Status = .notRegistered
    @Published private(set) var activePlan: CardImagingPlan?
    @Published private(set) var completionNotice: String?

    private let client: PrivilegedImagingClient
    private let sourceCoordinator: CardImagingSourceCoordinator
    private var imagingTask: Task<Void, Never>?
    private var cancellationReason: CancellationReason?

    init(
        client: PrivilegedImagingClient = PrivilegedImagingClient(),
        sourceCoordinator: CardImagingSourceCoordinator = CardImagingSourceCoordinator()
    ) {
        self.client = client
        self.sourceCoordinator = sourceCoordinator
        refreshHelperStatus()
    }

    var isActive: Bool {
        switch state {
        case .preparing, .imaging, .cancelling:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    func refreshHelperStatus() {
        helperStatus = client.serviceStatus
    }

    func installHelper() throws {
        try client.registerHelper()
        refreshHelperStatus()
        if helperStatus == .requiresApproval {
            PrivilegedImagingClient.openHelperApprovalSettings()
        }
    }

    func openHelperApprovalSettings() {
        PrivilegedImagingClient.openHelperApprovalSettings()
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
                let authorization = try PrivilegedImagingAuthorization.request()
                try await sourceCoordinator.prepareForImaging(plan: plan)
                sourceWasUnmounted = true
                try persistResumeRecord(for: plan)
                state = .imaging

                let request = PrivilegedImagingRequest(plan: plan)
                let result = try await client.image(
                    request: request,
                    authorization: authorization
                ) { snapshot in
                    await MainActor.run { self.progress = snapshot }
                }
                if let data = try? Data(contentsOf: plan.mapURL),
                   let snapshot = try? DDRescueMapfile.parse(
                    data,
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

    private func persistResumeRecord(for plan: CardImagingPlan) throws {
        do {
            let data = try JSONEncoder().encode(plan.resumeRecord)
            try data.write(to: plan.resumeRecordURL, options: .atomic)
        } catch {
            throw DDRescueRunner.RunnerError.failedToSaveResumeMetadata
        }
    }
}
