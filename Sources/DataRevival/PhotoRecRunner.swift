import Foundation

struct PhotoRecCommand: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL

    static func jpegScan(executableURL: URL, session: RecoverySession) -> PhotoRecCommand {
        PhotoRecCommand(
            executableURL: executableURL,
            arguments: [
                "/logname", session.logURL.path,
                "/d", session.recoveredOutputBaseURL.path,
                "/cmd", session.sourceImageURL.path,
                "fileopt,everything,disable,jpg,enable,wholespace,search"
            ],
            currentDirectoryURL: session.sessionDirectoryURL
        )
    }
}

enum PhotoRecExecutableLocator {
    static func locate(fileManager: FileManager = .default) -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "photorec"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/photorec",
            "/usr/local/bin/photorec",
            "/opt/local/bin/photorec"
        ]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }
}

final class PhotoRecRunner: @unchecked Sendable {
    enum RunnerError: LocalizedError {
        case alreadyRunning
        case failedToCreateLog
        case unsuccessfulExit(Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "A recovery scan is already running."
            case .failedToCreateLog:
                "The recovery process log could not be created."
            case .unsuccessfulExit(let status):
                "PhotoRec stopped with exit status \(status). See runner.log for details."
            }
        }
    }

    private let lock = NSLock()
    private var activeProcess: Process?

    func recover(command: PhotoRecCommand) async throws -> [RecoveredFile] {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL

        let runnerLogURL = command.currentDirectoryURL.appendingPathComponent("runner.log")
        FileManager.default.createFile(atPath: runnerLogURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: runnerLogURL) else {
            throw RunnerError.failedToCreateLog
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        try lock.withLock {
            guard activeProcess == nil else { throw RunnerError.alreadyRunning }
            activeProcess = process
        }

        defer {
            lock.withLock { activeProcess = nil }
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
        let files = try Self.collectRecoveredFiles(in: command.currentDirectoryURL)
        return RecoveredFileValidator.validate(files)
    }

    func cancel() {
        lock.withLock {
            guard let activeProcess, activeProcess.isRunning else { return }
            activeProcess.interrupt()
        }
    }

    static func collectRecoveredFiles(
        in sessionDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> [RecoveredFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [RecoveredFile] = []
        for case let url as URL in enumerator {
            guard url.deletingLastPathComponent().lastPathComponent.hasPrefix("recovered.") else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            results.append(
                RecoveredFile(
                    id: UUID(),
                    path: url.path,
                    byteCount: Int64(values.fileSize ?? 0),
                    validationStatus: .notChecked
                )
            )
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
