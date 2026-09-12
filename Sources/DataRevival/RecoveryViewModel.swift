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
                sessions = try await store.loadAll()
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
                    try? await store.save(cancelled)
                    activeSession = cancelled
                }
            } catch {
                if var failed = session {
                    failed.status = .failed
                    failed.updatedAt = .now
                    failed.failureMessage = error.localizedDescription
                    try? await store.save(failed)
                    activeSession = failed
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
}
