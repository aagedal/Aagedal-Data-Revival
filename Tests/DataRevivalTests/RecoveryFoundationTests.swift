import Foundation
import CoreGraphics
import DiskArbitration
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DataRevival

@Suite("Recovery foundation")
struct RecoveryFoundationTests {
    @Test("Disk discovery keeps only whole recovery-source devices")
    func storageDeviceFiltering() throws {
        let external = try #require(StorageDevice(
            bsdName: "disk7",
            description: [
                kDADiskDescriptionMediaWholeKey as String: true,
                kDADiskDescriptionMediaNameKey as String: "Camera Card",
                kDADiskDescriptionDeviceModelKey as String: "Reader",
                kDADiskDescriptionDeviceProtocolKey as String: "USB",
                kDADiskDescriptionMediaSizeKey as String: NSNumber(value: 64_000_000_000),
                kDADiskDescriptionDeviceInternalKey as String: false,
                kDADiskDescriptionMediaRemovableKey as String: true,
                kDADiskDescriptionMediaEjectableKey as String: true
            ]
        ))
        #expect(external.isRecoverySourceCandidate)
        #expect(external.displayName == "Camera Card")
        #expect(external.devicePath == "/dev/disk7")
        #expect(external.byteCount == 64_000_000_000)

        let internalDisk = try #require(StorageDevice(
            bsdName: "disk0",
            description: [
                kDADiskDescriptionMediaWholeKey as String: true,
                kDADiskDescriptionDeviceModelKey as String: "Internal SSD",
                kDADiskDescriptionDeviceInternalKey as String: true,
                kDADiskDescriptionMediaRemovableKey as String: false,
                kDADiskDescriptionMediaEjectableKey as String: false
            ]
        ))
        #expect(!internalDisk.isRecoverySourceCandidate)

        #expect(StorageDevice(
            bsdName: "disk7s1",
            description: [kDADiskDescriptionMediaWholeKey as String: false]
        ) == nil)
    }

    @Test("Card identity detects a replacement at a reused BSD path")
    func cardImagingIdentity() throws {
        let guid = Data([1, 2, 3, 4])
        let selected = try #require(makeStorageDevice(bsdName: "disk7", guid: guid))
        let unchanged = try #require(makeStorageDevice(bsdName: "disk7", guid: guid))
        let replacement = try #require(makeStorageDevice(bsdName: "disk7", guid: Data([9, 8, 7, 6])))

        #expect(selected.hasSameImagingIdentity(as: unchanged))
        #expect(!selected.hasSameImagingIdentity(as: replacement))
    }

    @Test("Card image planning rejects the source device and unsafe outputs")
    func cardImagePlanProtection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalImagingPlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000))
        let image = root.appendingPathComponent("camera card.img")

        #expect(throws: CardImagingError.sourceSizeUnknown) {
            try CardImagingPlan.prepare(
                sourceDevice: #require(makeStorageDevice(bsdName: "disk7", byteCount: 0)),
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: 128_000
            )
        }
        #expect(throws: CardImagingError.sourceDestinationCollision) {
            try CardImagingPlan.prepare(
                sourceDevice: source,
                imageURL: image,
                destinationWholeDiskBSDName: "disk7",
                availableCapacity: 128_000
            )
        }
        #expect(throws: CardImagingError.insufficientSpace(required: 64_000, available: 32_000)) {
            try CardImagingPlan.prepare(
                sourceDevice: source,
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: 32_000
            )
        }
        #expect(throws: CardImagingError.destinationCapacityUnknown) {
            try CardImagingPlan.prepare(
                sourceDevice: source,
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: nil
            )
        }

        try Data([0]).write(to: image.appendingPathExtension("map"))
        #expect(throws: CardImagingError.outputAlreadyExists) {
            try CardImagingPlan.prepare(
                sourceDevice: source,
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: 128_000
            )
        }
    }

    @Test("GNU ddrescue receives source, image, and mapfile as separate arguments")
    func ddrescueCommandPreservesPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recovery Drive \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000))
        let plan = try CardImagingPlan.prepare(
            sourceDevice: source,
            imageURL: root.appendingPathComponent("camera card.img"),
            destinationWholeDiskBSDName: "disk2",
            availableCapacity: 128_000
        )
        let command = DDRescueCommand.image(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ddrescue"),
            plan: plan
        )

        #expect(command.arguments == [
            "--verbose",
            "/dev/rdisk7",
            root.appendingPathComponent("camera card.img").path,
            root.appendingPathComponent("camera card.img.map").path
        ])
        #expect(command.runnerLogURL.lastPathComponent == "camera card.img.ddrescue.log")
    }

    @Test("GNU ddrescue runner invokes a process without a shell")
    func ddrescueRunnerExecutesProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalDDRescueRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = DDRescueCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            currentDirectoryURL: root,
            runnerLogURL: root.appendingPathComponent("ddrescue.log")
        )
        try await DDRescueRunner().image(command: command)

        #expect(FileManager.default.fileExists(atPath: command.runnerLogURL.path))
    }

    @Test("Card imaging writes source-bound metadata before invoking ddrescue")
    func cardImagingPersistsResumeMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalResumeMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000))
        let plan = try CardImagingPlan.prepare(
            sourceDevice: source,
            imageURL: root.appendingPathComponent("camera.img"),
            destinationWholeDiskBSDName: "disk2",
            availableCapacity: 128_000
        )
        let command = DDRescueCommand.image(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            plan: plan
        )

        try await DDRescueRunner().image(command: command)

        let data = try Data(contentsOf: plan.resumeRecordURL)
        let record = try JSONDecoder().decode(CardImagingResumeRecord.self, from: data)
        #expect(record == plan.resumeRecord)
        #expect(record.source.matches(source))
    }

    @Test("An interrupted card image resumes only with its original source")
    func cardImageResumeProtection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalResumePlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let guid = Data([1, 2, 3, 4])
        let original = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000, guid: guid))
        let image = root.appendingPathComponent("camera.img")
        let initialPlan = try CardImagingPlan.prepare(
            sourceDevice: original,
            imageURL: image,
            destinationWholeDiskBSDName: "disk2",
            availableCapacity: 128_000
        )
        try Data(repeating: 0, count: 16_000).write(to: image)
        try Data(interruptedMapfile(byteCount: original.byteCount).utf8).write(to: initialPlan.mapURL)
        try JSONEncoder().encode(initialPlan.resumeRecord).write(to: initialPlan.resumeRecordURL)

        let reconnected = try #require(makeStorageDevice(
            bsdName: "disk9",
            byteCount: 64_000,
            guid: guid
        ))
        let resumed = try CardImagingPlan.prepareResume(
            sourceDevice: reconnected,
            imageURL: image,
            destinationWholeDiskBSDName: "disk2",
            availableCapacity: 64_000
        )
        #expect(resumed.mode == .resume)
        #expect(resumed.sourceDevice.bsdName == "disk9")

        let resumeCommand = DDRescueCommand.image(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            plan: resumed
        )
        try await DDRescueRunner().image(command: resumeCommand)
        #expect(resumeCommand.arguments.contains("/dev/rdisk9"))
        let persistedRecord = try JSONDecoder().decode(
            CardImagingResumeRecord.self,
            from: Data(contentsOf: initialPlan.resumeRecordURL)
        )
        #expect(persistedRecord == initialPlan.resumeRecord)

        let replacement = try #require(makeStorageDevice(
            bsdName: "disk9",
            byteCount: 64_000,
            guid: Data([9, 8, 7, 6])
        ))
        #expect(throws: CardImagingError.resumeSourceMismatch) {
            try CardImagingPlan.prepareResume(
                sourceDevice: replacement,
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: 64_000
            )
        }
    }

    @Test("Card image resume requires a mapfile and remaining destination space")
    func cardImageResumeRequirements() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalResumeRequirements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000))
        let image = root.appendingPathComponent("camera.img")
        let initialPlan = try CardImagingPlan.prepare(
            sourceDevice: source,
            imageURL: image,
            destinationWholeDiskBSDName: "disk2",
            availableCapacity: 128_000
        )
        try Data(repeating: 0, count: 16_000).write(to: image)
        try JSONEncoder().encode(initialPlan.resumeRecord).write(to: initialPlan.resumeRecordURL)

        #expect(throws: CardImagingError.resumeFilesMissing) {
            try CardImagingPlan.prepareResume(
                sourceDevice: source,
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: 48_000
            )
        }

        try Data("not a ddrescue mapfile".utf8).write(to: initialPlan.mapURL)
        #expect(throws: CardImagingError.resumeMapInvalid) {
            try CardImagingPlan.prepareResume(
                sourceDevice: source,
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: 48_000
            )
        }

        try Data(interruptedMapfile(byteCount: source.byteCount).utf8).write(to: initialPlan.mapURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        let allocated = min(
            (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0,
            source.byteCount
        )
        let required = source.byteCount - allocated
        #expect(throws: CardImagingError.insufficientSpace(required: required, available: required - 1)) {
            try CardImagingPlan.prepareResume(
                sourceDevice: source,
                imageURL: image,
                destinationWholeDiskBSDName: "disk2",
                availableCapacity: required - 1
            )
        }
    }

    @Test("ddrescue mapfile parsing validates its domain and summarizes block states")
    func ddrescueMapfileValidation() throws {
        let mapfile = """
        # Mapfile. Created by GNU ddrescue
        # current_pos current_status current_pass
        0x00007000 ? 1
        # pos size status
        0x00000000 0x00004000 +
        0x00004000 0x00001000 -
        0x00005000 0x00002000 *
        0x00007000 0x00009000 ?
        """

        let snapshot = try DDRescueMapfile.parse(
            Data(mapfile.utf8),
            expectedByteCount: 65_536
        )
        #expect(snapshot.currentPosition == 28_672)
        #expect(snapshot.currentStatus == "?")
        #expect(snapshot.currentPass == 1)
        #expect(snapshot.rescuedByteCount == 16_384)
        #expect(snapshot.badSectorByteCount == 4_096)
        #expect(snapshot.pendingByteCount == 45_056)
        #expect(snapshot.totalByteCount == 65_536)
        #expect(snapshot.rescuedFraction == 0.25)
        #expect(!snapshot.isFinished)

        let mapfileWithGap = """
        0 ? 1
        0 1024 +
        2048 63488 ?
        """
        #expect(throws: DDRescueMapfile.ParseError.invalid) {
            try DDRescueMapfile.parse(
                Data(mapfileWithGap.utf8),
                expectedByteCount: 65_536
            )
        }
    }

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

    @Test("Opening an older session validates files without changing their identity")
    func refreshRecoveredFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalRefresh-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("camera.dd")
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([0x00]).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecoverySessionStore(catalogDirectory: catalog)
        var session = try await store.createSession(sourceImage: source, destinationRoot: destination)
        let recoveredDirectory = session.sessionDirectoryURL.appendingPathComponent("recovered.1", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveredDirectory, withIntermediateDirectories: true)
        let recoveredURL = recoveredDirectory.appendingPathComponent("photo.jpg")
        try writeTestJPEG(to: recoveredURL)
        let originalID = UUID()
        session.status = .completed
        session.recoveredFiles = [RecoveredFile(
            id: originalID,
            path: recoveredURL.path,
            byteCount: Int64((try Data(contentsOf: recoveredURL)).count),
            validationStatus: .notChecked
        )]
        try await store.save(session)

        let refreshed = try await store.refreshRecoveredFiles(for: session.id)
        #expect(refreshed.recoveredFiles.first?.id == originalID)
        #expect(refreshed.recoveredFiles.first?.validationStatus == .readable)

        let reloaded = try await RecoverySessionStore(catalogDirectory: catalog).loadAll()
        #expect(reloaded.first?.recoveredFiles.first?.validationStatus == .readable)
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

    @Test("JPEG validation distinguishes a decoded image from truncated data")
    func jpegValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let completeURL = root.appendingPathComponent("complete.jpg")
        try writeTestJPEG(to: completeURL)
        let complete = RecoveredFile(
            id: UUID(),
            path: completeURL.path,
            byteCount: Int64((try Data(contentsOf: completeURL)).count),
            validationStatus: .notChecked
        )

        let truncatedURL = root.appendingPathComponent("truncated.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: truncatedURL)
        let truncated = RecoveredFile(
            id: UUID(),
            path: truncatedURL.path,
            byteCount: 4,
            validationStatus: .notChecked
        )

        #expect(RecoveredFileValidator.validate(complete).validationStatus == .readable)
        #expect(RecoveredFileValidator.validate(truncated).validationStatus == .possiblyPartial)
    }

    @Test("Export keeps existing files and chooses a unique name")
    func collisionSafeExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalExport-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = sourceDirectory.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: source)
        try Data([9]).write(to: destination.appendingPathComponent("photo.jpg"))
        let file = RecoveredFile(
            id: UUID(),
            path: source.path,
            byteCount: 3,
            validationStatus: .readable
        )

        let exported = try RecoveryExporter.export([file], to: destination)
        #expect(exported.first?.lastPathComponent == "photo 2.jpg")
        #expect(try Data(contentsOf: destination.appendingPathComponent("photo.jpg")) == Data([9]))
        #expect(try Data(contentsOf: #require(exported.first)) == Data([1, 2, 3]))
    }

    private func writeTestJPEG(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let pixels: [UInt8] = [20, 120, 220, 255]
        let data = Data(pixels)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func makeStorageDevice(
        bsdName: String,
        byteCount: Int64 = 64_000_000_000,
        guid: Data? = Data([1, 2, 3, 4])
    ) -> StorageDevice? {
        var description: [String: Any] = [
            kDADiskDescriptionMediaWholeKey as String: true,
            kDADiskDescriptionMediaNameKey as String: "Camera Card",
            kDADiskDescriptionDeviceModelKey as String: "Reader",
            kDADiskDescriptionDeviceProtocolKey as String: "USB",
            kDADiskDescriptionMediaSizeKey as String: NSNumber(value: byteCount),
            kDADiskDescriptionDeviceInternalKey as String: false,
            kDADiskDescriptionMediaRemovableKey as String: true,
            kDADiskDescriptionMediaEjectableKey as String: true
        ]
        if let guid {
            description[kDADiskDescriptionDeviceGUIDKey as String] = guid
        }
        return StorageDevice(bsdName: bsdName, description: description)
    }
}

private func interruptedMapfile(byteCount: Int64) -> String {
    let rescued = byteCount / 4
    let pending = byteCount - rescued
    return """
    # Mapfile. Created by GNU ddrescue
    \(rescued) ? 1
    0 \(rescued) +
    \(rescued) \(pending) ?
    """
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
