import Foundation
import Combine

@MainActor
final class RecoveryViewModel: ObservableObject {
    @Published private(set) var sessions: [RecoverySession] = []
    @Published private(set) var activeSession: RecoverySession?
    @Published private(set) var recoveredFiles: [RecoveredFile] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let store: RecoverySessionStore
    private var runner: PhotoRecRunner?
    private var scanTask: Task<Void, Never>?

    init(store: RecoverySessionStore = .live) {
        self.store = store
    }

    func loadSessions() {
        Task {
            do {
                sessions = try await store.reconcileInterruptedSessions()
            } catch {
                errorMessage = "Saved recovery sessions could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    func startJPEGScan(sourceImage: URL, destinationRoot: URL, executableURL: URL) {
        guard !isScanning else { return }
        isScanning = true
        recoveredFiles = []
        activeSession = nil

        scanTask = Task {
            var session: RecoverySession?
            do {
                var created = try await store.createSession(
                    sourceImage: sourceImage,
                    destinationRoot: destinationRoot
                )
                created.status = .scanning
                created.updatedAt = .now
                try await store.save(created)
                session = created
                activeSession = created

                let runner = PhotoRecRunner()
                self.runner = runner
                let command = PhotoRecCommand.jpegScan(executableURL: executableURL, session: created)
                let files = try await runner.recover(command: command)

                created.status = .completed
                created.updatedAt = .now
                created.recoveredFiles = files
                try await store.save(created)
                activeSession = created
                recoveredFiles = files
            } catch is CancellationError {
                if var cancelled = session {
                    cancelled.status = .cancelled
                    cancelled.updatedAt = .now
                    cancelled.recoveredFiles = await collectPartialFiles(for: cancelled)
                    try? await store.save(cancelled)
                    activeSession = cancelled
                    recoveredFiles = cancelled.recoveredFiles
                }
            } catch {
                if var failed = session {
                    failed.status = .failed
                    failed.updatedAt = .now
                    failed.failureMessage = error.localizedDescription
                    failed.recoveredFiles = await collectPartialFiles(for: failed)
                    try? await store.save(failed)
                    activeSession = failed
                    recoveredFiles = failed.recoveredFiles
                }
                errorMessage = error.localizedDescription
            }

            runner = nil
            scanTask = nil
            isScanning = false
            sessions = (try? await store.loadAll()) ?? sessions
        }
    }

    func cancelScan() {
        runner?.cancel()
        scanTask?.cancel()
    }

    func dismissActiveSession() {
        guard !isScanning else { return }
        activeSession = nil
        recoveredFiles = []
    }

    func openSession(id: RecoverySession.ID) {
        guard !isScanning, let session = sessions.first(where: { $0.id == id }) else { return }
        activeSession = session
        recoveredFiles = session.recoveredFiles

        Task {
            do {
                let refreshed = try await store.refreshRecoveredFiles(for: id)
                guard activeSession?.id == id, !isScanning else { return }
                activeSession = refreshed
                recoveredFiles = refreshed.recoveredFiles
                sessions = try await store.loadAll()
            } catch {
                errorMessage = "The saved session could not be refreshed: \(error.localizedDescription)"
            }
        }
    }

    func exportFiles(ids: Set<RecoveredFile.ID>, to destinationDirectory: URL) async throws -> [URL] {
        let files = recoveredFiles.filter { ids.contains($0.id) }
        return try await Task.detached {
            try RecoveryExporter.export(files, to: destinationDirectory)
        }.value
    }

    private func collectPartialFiles(for session: RecoverySession) async -> [RecoveredFile] {
        await Task.detached {
            guard let files = try? PhotoRecRunner.collectRecoveredFiles(in: session.sessionDirectoryURL) else {
                return session.recoveredFiles
            }
            return RecoveredFileValidator.validate(files)
        }.value
    }
}
