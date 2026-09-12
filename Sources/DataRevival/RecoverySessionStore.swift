import Foundation

actor RecoverySessionStore {
    enum StoreError: LocalizedError {
        case sourceIsNotAFile
        case destinationIsNotDirectory
        case sourceDestinationCollision
        case sessionNotFound

        var errorDescription: String? {
            switch self {
            case .sourceIsNotAFile:
                "The recovery source must be a readable, nonempty regular file."
            case .destinationIsNotDirectory:
                "Choose a writable destination folder."
            case .sourceDestinationCollision:
                "The recovery output cannot replace or be stored inside the source image."
            case .sessionNotFound:
                "The selected recovery session is no longer in the session catalog."
            }
        }
    }

    static let live = RecoverySessionStore(catalogDirectory: RecoverySessionStore.defaultCatalogDirectory())

    private let catalogDirectory: URL
    private let fileManager: FileManager
    private var sessions: [RecoverySession]?

    init(catalogDirectory: URL, fileManager: FileManager = .default) {
        self.catalogDirectory = catalogDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    func loadAll() throws -> [RecoverySession] {
        if let sessions {
            return sessions.sorted { $0.updatedAt > $1.updatedAt }
        }

        let catalogURL = catalogDirectory.appendingPathComponent("sessions.json")
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            sessions = []
            return []
        }

        let data = try Data(contentsOf: catalogURL)
        let decoded = try Self.decoder.decode([RecoverySession].self, from: data)
        sessions = decoded
        return decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Repairs manifests left in a transient state when the app stopped while
    /// PhotoRec was running. Any output already written by PhotoRec remains
    /// useful and is added to the session before it is persisted.
    func reconcileInterruptedSessions() throws -> [RecoverySession] {
        var catalog = try loadAll()
        var changedSessions: [RecoverySession] = []

        for index in catalog.indices where catalog[index].status == .scanning {
            var session = catalog[index]
            session.status = .interrupted
            session.updatedAt = .now
            session.failureMessage = "The app stopped before this scan finished. Partial output was preserved."
            if let files = try? PhotoRecRunner.collectRecoveredFiles(
                in: session.sessionDirectoryURL,
                fileManager: fileManager
            ) {
                session.recoveredFiles = RecoveredFileValidator.validate(files)
            }
            catalog[index] = session
            changedSessions.append(session)
        }

        guard !changedSessions.isEmpty else {
            return catalog.sorted { $0.updatedAt > $1.updatedAt }
        }

        try fileManager.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        for session in changedSessions {
            let manifestData = try Self.encoder.encode(session)
            try manifestData.write(to: session.manifestURL, options: .atomic)
        }
        sessions = catalog
        let catalogData = try Self.encoder.encode(catalog)
        try catalogData.write(
            to: catalogDirectory.appendingPathComponent("sessions.json"),
            options: .atomic
        )
        return catalog.sorted { $0.updatedAt > $1.updatedAt }
    }

    func refreshRecoveredFiles(for id: RecoverySession.ID) throws -> RecoverySession {
        let catalog = try loadAll()
        guard var session = catalog.first(where: { $0.id == id }) else {
            throw StoreError.sessionNotFound
        }

        let existingByPath = Dictionary(
            uniqueKeysWithValues: session.recoveredFiles.map { ($0.url.standardizedFileURL.path, $0) }
        )
        let collected = try PhotoRecRunner.collectRecoveredFiles(
            in: session.sessionDirectoryURL,
            fileManager: fileManager
        )
        let stableFiles = collected.map { file in
            guard let existing = existingByPath[file.url.standardizedFileURL.path] else { return file }
            return RecoveredFile(
                id: existing.id,
                path: file.path,
                byteCount: file.byteCount,
                validationStatus: existing.validationStatus
            )
        }
        let validated = RecoveredFileValidator.validate(stableFiles)

        if validated != session.recoveredFiles {
            session.recoveredFiles = validated
            session.updatedAt = .now
            try save(session)
        }
        return session
    }

    func createSession(sourceImage: URL, destinationRoot: URL) throws -> RecoverySession {
        let source = sourceImage.resolvingSymlinksInPath().standardizedFileURL
        let destination = destinationRoot.resolvingSymlinksInPath().standardizedFileURL

        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
        guard sourceValues.isRegularFile == true,
              sourceValues.isReadable == true,
              (sourceValues.fileSize ?? 0) > 0 else {
            throw StoreError.sourceIsNotAFile
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StoreError.destinationIsNotDirectory
        }

        // A regular source image cannot contain a directory, but this also guards
        // against choosing the image itself through an alias or symlink.
        guard source.path != destination.path,
              !destination.path.hasPrefix(source.path + "/") else {
            throw StoreError.sourceDestinationCollision
        }

        let id = UUID()
        let sessionDirectory = destination.appendingPathComponent("DataRevival-\(id.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)

        let now = Date()
        let session = RecoverySession(
            id: id,
            createdAt: now,
            updatedAt: now,
            sourceImagePath: source.path,
            sessionDirectoryPath: sessionDirectory.path,
            status: .ready,
            recoveredFiles: [],
            failureMessage: nil
        )
        try save(session)
        return session
    }

    func save(_ session: RecoverySession) throws {
        try fileManager.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: session.sessionDirectoryURL, withIntermediateDirectories: true)

        let manifestData = try Self.encoder.encode(session)
        try manifestData.write(to: session.manifestURL, options: .atomic)

        var catalog = try loadAll()
        if let index = catalog.firstIndex(where: { $0.id == session.id }) {
            catalog[index] = session
        } else {
            catalog.append(session)
        }
        sessions = catalog
        let catalogData = try Self.encoder.encode(catalog)
        try catalogData.write(
            to: catalogDirectory.appendingPathComponent("sessions.json"),
            options: .atomic
        )
    }

    private static func defaultCatalogDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DataRevival", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
