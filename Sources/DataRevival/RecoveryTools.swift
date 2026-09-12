import Foundation
import CryptoKit

enum RecoveryTool: String, CaseIterable, Identifiable, Sendable {
    case photoRec = "photorec"
    case ddrescue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photoRec: "PhotoRec"
        case .ddrescue: "GNU ddrescue"
        }
    }

    var developmentCandidates: [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(rawValue)"),
            URL(fileURLWithPath: "/usr/local/bin/\(rawValue)"),
            URL(fileURLWithPath: "/opt/local/bin/\(rawValue)")
        ]
    }

    var versionArguments: [String] {
        switch self {
        case .photoRec: ["/version"]
        case .ddrescue: ["--version"]
        }
    }
}

struct RecoveryToolInstallation: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        case appBundle
        case developmentInstall
    }

    let tool: RecoveryTool
    let executableURL: URL
    let origin: Origin
}

enum RecoveryToolInspector {
    static func provenance(
        for installation: RecoveryToolInstallation,
        arguments: [String]
    ) async -> RecoveryEngineProvenance {
        async let version = versionDescription(for: installation)
        async let digest = executableSHA256(at: installation.executableURL)

        return await RecoveryEngineProvenance(
            name: installation.tool.rawValue,
            versionDescription: version,
            executableSHA256: digest,
            processArchitecture: processArchitecture,
            origin: installation.origin == .appBundle ? .appBundle : .developmentInstall,
            arguments: arguments
        )
    }

    static func versionDescription(
        for installation: RecoveryToolInstallation
    ) async -> String? {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = installation.executableURL
            process.arguments = installation.tool.versionArguments
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                return text
                    .split(whereSeparator: \Character.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
            } catch {
                return nil
            }
        }.value
    }

    static func executableSHA256(at url: URL) async -> String? {
        await Task.detached {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

enum RecoveryToolLocator {
    /// Release builds deliberately ignore package-manager installations. A
    /// distributable app must contain every recovery engine that it launches.
    static var allowsDevelopmentFallback: Bool {
        _isDebugAssertConfiguration()
    }

    static func locate(
        _ tool: RecoveryTool,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        allowDevelopmentFallback: Bool = allowsDevelopmentFallback
    ) -> RecoveryToolInstallation? {
        let bundleRoot = bundle.bundleURL.resolvingSymlinksInPath()
        let bundledCandidates = bundledExecutableCandidates(for: tool, in: bundle)

        if let executable = bundledCandidates.first(where: {
            isExecutable($0, inside: bundleRoot, fileManager: fileManager)
        }) {
            return RecoveryToolInstallation(
                tool: tool,
                executableURL: executable,
                origin: .appBundle
            )
        }

        guard allowDevelopmentFallback,
              let executable = tool.developmentCandidates.first(where: {
                  fileManager.isExecutableFile(atPath: $0.path)
              }) else {
            return nil
        }

        return RecoveryToolInstallation(
            tool: tool,
            executableURL: executable,
            origin: .developmentInstall
        )
    }

    static func selectInstallation(
        for tool: RecoveryTool,
        bundledCandidates: [URL],
        bundleRoot: URL,
        developmentCandidates: [URL],
        allowDevelopmentFallback: Bool,
        fileManager: FileManager = .default
    ) -> RecoveryToolInstallation? {
        if let executable = bundledCandidates.first(where: {
            isExecutable($0, inside: bundleRoot, fileManager: fileManager)
        }) {
            return RecoveryToolInstallation(
                tool: tool,
                executableURL: executable,
                origin: .appBundle
            )
        }

        guard allowDevelopmentFallback,
              let executable = developmentCandidates.first(where: {
                  fileManager.isExecutableFile(atPath: $0.path)
              }) else {
            return nil
        }

        return RecoveryToolInstallation(
            tool: tool,
            executableURL: executable,
            origin: .developmentInstall
        )
    }

    static func unavailableMessage(for tool: RecoveryTool) -> String {
        if allowsDevelopmentFallback {
            return "\(tool.displayName) is unavailable. Add it to the app bundle or install its development package, then try again."
        }
        return "This build does not contain the signed \(tool.displayName) engine required for this operation."
    }

    private static func bundledExecutableCandidates(
        for tool: RecoveryTool,
        in bundle: Bundle
    ) -> [URL] {
        var candidates: [URL] = []
        if let auxiliary = bundle.url(forAuxiliaryExecutable: tool.rawValue) {
            candidates.append(auxiliary)
        }
        candidates.append(
            bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent(tool.rawValue)
        )
        return candidates
    }

    private static func isExecutable(
        _ candidate: URL,
        inside bundleRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let rootPath = bundleRoot.path.hasSuffix("/") ? bundleRoot.path : bundleRoot.path + "/"
        guard resolvedCandidate.path.hasPrefix(rootPath) else { return false }
        return fileManager.isExecutableFile(atPath: resolvedCandidate.path)
    }
}
