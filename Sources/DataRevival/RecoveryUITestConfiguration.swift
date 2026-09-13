import Foundation

/// Deterministic file locations used only by the UI-test process. The explicit
/// launch argument and Debug-build check keep these overrides out of normal use.
struct RecoveryUITestConfiguration {
    static let launchArgument = "--data-revival-ui-testing"

    let catalogDirectory: URL
    let sourceImage: URL
    let recoveryDestination: URL
    let recoveredFixture: URL
    let exportDestination: URL

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RecoveryUITestConfiguration? {
        #if DEBUG
        guard arguments.contains(launchArgument) else {
            return nil
        }

        let requiredKeys = [
            "DATA_REVIVAL_UI_TEST_CATALOG",
            "DATA_REVIVAL_UI_TEST_SOURCE",
            "DATA_REVIVAL_UI_TEST_RECOVERY_DESTINATION",
            "DATA_REVIVAL_UI_TEST_FIXTURE",
            "DATA_REVIVAL_UI_TEST_EXPORT_DESTINATION"
        ]
        guard requiredKeys.allSatisfy({ environment[$0]?.isEmpty == false }) else {
            return nil
        }

        return RecoveryUITestConfiguration(
            catalogDirectory: URL(fileURLWithPath: environment[requiredKeys[0]]!, isDirectory: true),
            sourceImage: URL(fileURLWithPath: environment[requiredKeys[1]]!),
            recoveryDestination: URL(fileURLWithPath: environment[requiredKeys[2]]!, isDirectory: true),
            recoveredFixture: URL(fileURLWithPath: environment[requiredKeys[3]]!),
            exportDestination: URL(fileURLWithPath: environment[requiredKeys[4]]!, isDirectory: true)
        )
        #else
        return nil
        #endif
    }
}

final class RecoveryFixtureRunner: PhotoRecRunning, @unchecked Sendable {
    private let fixtureURL: URL

    init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    func recover(
        command: PhotoRecCommand,
        onProgress: (@Sendable (RecoveryScanProgress) async -> Void)?
    ) async throws -> [RecoveredFile] {
        let outputDirectory = command.currentDirectoryURL
            .appendingPathComponent("recovered.1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixtureURL,
            to: outputDirectory.appendingPathComponent("recovered.jpg")
        )
        if let onProgress {
            await onProgress(.snapshot(
                in: command.currentDirectoryURL,
                startedAt: .now
            ))
        }
        return RecoveredFileValidator.validate(
            try PhotoRecRunner.collectRecoveredFiles(in: command.currentDirectoryURL)
        )
    }

    func cancel() {}
}
