import Foundation

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
