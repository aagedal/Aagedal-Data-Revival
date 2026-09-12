import Foundation
import Testing
@testable import DataRevival

@Suite("Recovery foundation")
struct RecoveryFoundationTests {
    @Test("PhotoRec receives paths as separate arguments")
    func commandPreservesPathsWithSpaces() {
        let session = RecoverySession(
            id: UUID(),
            createdAt: .now,
            updatedAt: .now,
            sourceImagePath: "/Volumes/Test Images/card copy.dd",
            sessionDirectoryPath: "/Volumes/Recovery Drive/session",
            status: .ready,
            recoveredFiles: [],
            failureMessage: nil
        )

        let command = PhotoRecCommand.jpegScan(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/photorec"),
            session: session
        )

        #expect(command.arguments[1] == "/Volumes/Recovery Drive/session/photorec.log")
        #expect(command.arguments[3] == "/Volumes/Recovery Drive/session/recovered")
        #expect(command.arguments[5] == "/Volumes/Test Images/card copy.dd")
        #expect(command.arguments.last == "fileopt,everything,disable,jpg,enable,wholespace,search")
    }

    @Test("Sessions are written to their folder and catalog")
    func sessionRoundTrip() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalTests-\(UUID().uuidString)", isDirectory: true)
        let source = temporaryRoot.appendingPathComponent("camera card.dd")
        let destination = temporaryRoot.appendingPathComponent("output", isDirectory: true)
        let catalog = temporaryRoot.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: source)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = RecoverySessionStore(catalogDirectory: catalog)
        var session = try await store.createSession(sourceImage: source, destinationRoot: destination)
        session.status = .completed
        session.updatedAt = session.createdAt.addingTimeInterval(1)
        try await store.save(session)

        let reloaded = try await RecoverySessionStore(catalogDirectory: catalog).loadAll()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == session.id)
        #expect(reloaded.first?.status == .completed)
        #expect(abs((reloaded.first?.updatedAt.timeIntervalSince1970 ?? 0) - session.updatedAt.timeIntervalSince1970) < 1)
        #expect(FileManager.default.fileExists(atPath: session.manifestURL.path))
    }

    @Test("Interrupted scans retain partial files and become reopenable")
    func interruptedSessionReconciliation() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalInterrupted-\(UUID().uuidString)", isDirectory: true)
        let source = temporaryRoot.appendingPathComponent("camera.dd")
        let destination = temporaryRoot.appendingPathComponent("output", isDirectory: true)
        let catalog = temporaryRoot.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([0x00]).write(to: source)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = RecoverySessionStore(catalogDirectory: catalog)
        var session = try await store.createSession(sourceImage: source, destinationRoot: destination)
        session.status = .scanning
        try await store.save(session)

        let output = session.sessionDirectoryURL.appendingPathComponent("recovered.1", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: output.appendingPathComponent("partial.jpg"))

        let reconciled = try await RecoverySessionStore(catalogDirectory: catalog)
            .reconcileInterruptedSessions()
        let restored = try #require(reconciled.first)
        #expect(restored.status == .interrupted)
        #expect(restored.recoveredFiles.count == 1)
        #expect(restored.recoveredFiles.first?.name == "partial.jpg")

        let manifestData = try Data(contentsOf: restored.manifestURL)
        let manifest = try JSONDecoder.iso8601.decode(RecoverySession.self, from: manifestData)
        #expect(manifest.status == .interrupted)
        #expect(manifest.recoveredFiles.count == 1)
    }

    @Test("Recovered files are found only under PhotoRec output folders")
    func collectRecoveredFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalFiles-\(UUID().uuidString)", isDirectory: true)
        let recovered = root.appendingPathComponent("recovered.1", isDirectory: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: recovered.appendingPathComponent("f000001.jpg"))
        try Data([4]).write(to: root.appendingPathComponent("runner.log"))
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try PhotoRecRunner.collectRecoveredFiles(in: root)
        #expect(files.count == 1)
        #expect(files.first?.name == "f000001.jpg")
        #expect(files.first?.byteCount == 3)
    }

    @Test("Runner handles a successful process without shell invocation")
    func runnerExecutesProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = PhotoRecCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            currentDirectoryURL: root
        )
        let files = try await PhotoRecRunner().recover(command: command)

        #expect(files.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("runner.log").path))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
