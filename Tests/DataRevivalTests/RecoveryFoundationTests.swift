import Foundation
import CoreGraphics
import Darwin
import DiskArbitration
import ImageIO
import Security
import Testing
import UniformTypeIdentifiers
@testable import DataRevival

@Suite("Recovery foundation")
struct RecoveryFoundationTests {
    @Test("Recovery tools prefer bundled executables and release mode has no external fallback")
    func recoveryToolResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalToolLocator-\(UUID().uuidString)", isDirectory: true)
        let bundleRoot = root.appendingPathComponent("Data Revival.app", isDirectory: true)
        let helpers = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        let bundled = helpers.appendingPathComponent("photorec")
        let development = root.appendingPathComponent("homebrew-photorec")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bundled)
        try Data("#!/bin/sh\n".utf8).write(to: development)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: bundled.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: development.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let preferred = RecoveryToolLocator.selectInstallation(
            for: .photoRec,
            bundledCandidates: [bundled],
            bundleRoot: bundleRoot,
            developmentCandidates: [development],
            allowDevelopmentFallback: true
        )
        #expect(preferred?.origin == .appBundle)
        #expect(preferred?.executableURL == bundled)

        try FileManager.default.removeItem(at: bundled)
        let releaseResult = RecoveryToolLocator.selectInstallation(
            for: .photoRec,
            bundledCandidates: [bundled],
            bundleRoot: bundleRoot,
            developmentCandidates: [development],
            allowDevelopmentFallback: false
        )
        #expect(releaseResult == nil)

        let debugResult = RecoveryToolLocator.selectInstallation(
            for: .photoRec,
            bundledCandidates: [bundled],
            bundleRoot: bundleRoot,
            developmentCandidates: [development],
            allowDevelopmentFallback: true
        )
        #expect(debugResult?.origin == .developmentInstall)
    }

    @Test("A bundled recovery tool cannot escape the app through a symlink")
    func bundledToolSymlinkProtection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalToolSymlink-\(UUID().uuidString)", isDirectory: true)
        let bundleRoot = root.appendingPathComponent("Data Revival.app", isDirectory: true)
        let helpers = bundleRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        let external = root.appendingPathComponent("external-photorec")
        let link = helpers.appendingPathComponent("photorec")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: external)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: external.path
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        defer { try? FileManager.default.removeItem(at: root) }

        let installation = RecoveryToolLocator.selectInstallation(
            for: .photoRec,
            bundledCandidates: [link],
            bundleRoot: bundleRoot,
            developmentCandidates: [],
            allowDevelopmentFallback: false
        )
        #expect(installation == nil)
    }

    @Test("Recovery engine provenance records version, digest, architecture, and arguments")
    func recoveryEngineProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalProvenance-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("photorec")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 'PhotoRec 7.2, Data Recovery Utility'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let provenance = await RecoveryToolInspector.provenance(
            for: RecoveryToolInstallation(
                tool: .photoRec,
                executableURL: executable,
                origin: .developmentInstall
            ),
            arguments: ["/cmd", "/tmp/card.dd", "fileopt,everything,disable"]
        )

        #expect(provenance.name == "photorec")
        #expect(provenance.versionDescription == "PhotoRec 7.2, Data Recovery Utility")
        #expect(provenance.executableSHA256?.count == 64)
        #expect(["arm64", "x86_64"].contains(provenance.processArchitecture))
        #expect(provenance.origin == .developmentInstall)
        #expect(provenance.arguments.first == "/cmd")
    }

    @Test("Production recovery engine sources are completely pinned")
    func recoveryEngineSourceLock() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lockURL = repositoryRoot
            .appendingPathComponent("Configuration/RecoveryEngines.lock.json")
        let lock = try JSONDecoder().decode(
            RecoveryEngineSourceLock.self,
            from: Data(contentsOf: lockURL)
        )

        #expect(lock.schemaVersion == 1)
        #expect(lock.target.architecture == "arm64")
        #expect(lock.target.minimumMacOS == "14.0")
        #expect(Set(lock.engines.keys) == ["photorec", "ddrescue"])

        for engine in lock.engines.values {
            #expect(!engine.version.isEmpty)
            #expect(engine.sourceURL.scheme == "https")
            #expect(engine.sourceURL.lastPathComponent == engine.sourceArchiveName)
            #expect(engine.releaseURL.scheme == "https")
            #expect(engine.sourceSHA256.count == 64)
            #expect(engine.sourceSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(engine.license == "GPL-2.0-or-later")
        }
        let ddrescuePatches = try #require(lock.engines["ddrescue"]?.patches)
        #expect(ddrescuePatches.count == 1)
        let ddrescuePatch = try #require(ddrescuePatches.first)
        #expect(ddrescuePatch.fileName == "ddrescue-inherited-stdin.patch")
        #expect(ddrescuePatch.sha256 == "d3555989d963b73be01cd7ecb05853c3edfb012c5ad0a62d3c6d370234ef5f91")
        #expect(lock.engines["photorec"]?.patches == nil)
    }

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

    @Test("Recovery storage planning reserves output space up to the source size")
    func recoveryStoragePlanning() throws {
        let estimate = RecoveryStorageEstimate(sourceByteCount: 64_000)
        #expect(estimate.cardImageByteCount == 64_000)
        #expect(estimate.recoveredOutputByteCount == 64_000)
        #expect(estimate.completeWorkflowByteCount == 128_000)

        try estimate.validateRecoveryOutputCapacity(64_000)
        #expect(throws: RecoveryStorageError.insufficientRecoverySpace(
            required: 64_000,
            available: 63_999
        )) {
            try estimate.validateRecoveryOutputCapacity(63_999)
        }
        #expect(throws: RecoveryStorageError.destinationCapacityUnknown) {
            try estimate.validateRecoveryOutputCapacity(nil)
        }
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

    @Test("Destination disk identity starts from the containing mount point")
    func destinationDiskIdentityUsesMountPoint() throws {
        let directory = FileManager.default.temporaryDirectory
        let mountURL = try DiskIdentityResolver.volumeMountURL(containing: directory)

        #expect(mountURL.path.hasPrefix("/"))
        #expect(try DiskIdentityResolver.wholeDiskBSDName(containing: directory) != nil)
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
            "--size=64000",
            "/dev/rdisk7",
            root.appendingPathComponent("camera card.img").path,
            root.appendingPathComponent("camera card.img.map").path
        ])
        #expect(command.runnerLogURL.lastPathComponent == "camera card.img.ddrescue.log")
        #expect(command.mapURL == plan.mapURL)
        #expect(command.sourceByteCount == source.byteCount)
        #expect(DiskLifecycleOperation.unmount.honorsPreflightCancellation)
        #expect(!DiskLifecycleOperation.mount.honorsPreflightCancellation)
        #expect(!DiskLifecycleOperation.eject.honorsPreflightCancellation)
    }

    @Test("authopen requests only path-specific read-only card access")
    func authopenInvocationIsReadOnlyAndPathSpecific() throws {
        let source = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000))
        let invocation = AuthopenInvocation(device: source)

        #expect(invocation.rawDeviceURL.path == "/dev/rdisk7")
        #expect(invocation.authorizationRight == "sys.openfile.readonly./dev/rdisk7")
        #expect(invocation.arguments == ["-stdoutpipe", "-extauth", "/dev/rdisk7"])
        #expect(
            AuthorizedImagingError.authorizationFailed(errAuthorizationCanceled)
                .errorDescription ==
                "Administrator authorization was cancelled. No card data was read."
        )
    }

    @Test("Authorized card handles must be read-only character devices")
    func authorizedDescriptorValidation() throws {
        let source = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000))
        let descriptor = open("/dev/null", O_RDONLY)
        defer { close(descriptor) }
        #expect(descriptor >= 0)

        try RawDeviceDescriptorValidator.validate(
            descriptor: descriptor,
            rawDevicePath: "/dev/null",
            expectedDevice: source,
            resolveDevice: { _ in source }
        )

        let writableDescriptor = open("/dev/null", O_RDWR)
        defer { close(writableDescriptor) }
        #expect(throws: AuthorizedImagingError.invalidRawDevice) {
            try RawDeviceDescriptorValidator.validate(
                descriptor: writableDescriptor,
                rawDevicePath: "/dev/null",
                expectedDevice: source,
                resolveDevice: { _ in source }
            )
        }
    }

    @Test("authopen file descriptors are received through SCM_RIGHTS")
    func authorizedDescriptorTransfer() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalDescriptorTransfer-\(UUID().uuidString)")
        try Data("authorized card bytes".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let sourceDescriptor = open(source.path, O_RDONLY)
        defer { close(sourceDescriptor) }

        try sendFileDescriptor(sourceDescriptor, to: sockets[1])
        let receivedDescriptor = try FileDescriptorReceiver.receive(from: sockets[0])
        defer { close(receivedDescriptor) }

        let handle = FileHandle(fileDescriptor: receivedDescriptor, closeOnDealloc: false)
        #expect(try handle.readToEnd() == Data("authorized card bytes".utf8))
    }

    @Test("A child imaging process can read an already-open source descriptor")
    func processInheritsImagingSourceDescriptor() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalInheritedDescriptor-\(UUID().uuidString)")
        try Data("read-only recovery source".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        defer { close(descriptor) }
        #expect(descriptor >= 0)

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = ["/dev/fd/0"]
        process.standardInput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let data = try output.fileHandleForReading.readToEnd()

        #expect(process.terminationStatus == 0)
        #expect(data == Data("read-only recovery source".utf8))
    }

    @Test("Card imaging revalidates identity around a non-forced whole-disk unmount")
    func cardImagingSourcePreparation() async throws {
        let source = try #require(makeStorageDevice(
            bsdName: "disk7",
            byteCount: 64_000,
            guid: Data([1, 2, 3, 4])
        ))
        let lifecycle = RecordingDiskLifecycleController()
        let resolver = DeviceResolutionSequence([source, source])
        let coordinator = CardImagingSourceCoordinator(
            lifecycle: lifecycle,
            resolveDevice: { resolver.next(bsdName: $0) }
        )
        let plan = CardImagingPlan(
            sourceDevice: source,
            imageURL: URL(fileURLWithPath: "/tmp/camera.img"),
            mapURL: URL(fileURLWithPath: "/tmp/camera.img.map"),
            runnerLogURL: URL(fileURLWithPath: "/tmp/camera.img.ddrescue.log"),
            resumeRecordURL: URL(fileURLWithPath: "/tmp/camera.img.datarevival.json"),
            resumeRecord: CardImagingResumeRecord(source: .init(device: source)),
            mapSnapshot: nil,
            mode: .create
        )

        let validated = try await coordinator.prepareForImaging(plan: plan)

        #expect(validated == source)
        #expect(resolver.resolutionCount == 2)
        #expect(await lifecycle.operations == [.unmount])

        try await coordinator.finishImaging(plan: plan, action: .remount)
        try await coordinator.finishImaging(plan: plan, action: .eject)
        #expect(await lifecycle.operations == [.unmount, .mount, .eject])
    }

    @Test("A changed source after unmount is rejected and remounted")
    func cardImagingRejectsPostUnmountReplacement() async throws {
        let selected = try #require(makeStorageDevice(
            bsdName: "disk7",
            byteCount: 64_000,
            guid: Data([1, 2, 3, 4])
        ))
        let replacement = try #require(makeStorageDevice(
            bsdName: "disk7",
            byteCount: 64_000,
            guid: Data([9, 8, 7, 6])
        ))
        let lifecycle = RecordingDiskLifecycleController()
        let resolver = DeviceResolutionSequence([selected, replacement])
        let coordinator = CardImagingSourceCoordinator(
            lifecycle: lifecycle,
            resolveDevice: { resolver.next(bsdName: $0) }
        )
        let plan = CardImagingPlan(
            sourceDevice: selected,
            imageURL: URL(fileURLWithPath: "/tmp/camera.img"),
            mapURL: URL(fileURLWithPath: "/tmp/camera.img.map"),
            runnerLogURL: URL(fileURLWithPath: "/tmp/camera.img.ddrescue.log"),
            resumeRecordURL: URL(fileURLWithPath: "/tmp/camera.img.datarevival.json"),
            resumeRecord: CardImagingResumeRecord(source: .init(device: selected)),
            mapSnapshot: nil,
            mode: .create
        )

        await #expect(throws: CardImagingError.sourceIdentityChanged) {
            try await coordinator.prepareForImaging(plan: plan)
        }
        #expect(await lifecycle.operations == [.unmount, .mount])
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

    @Test("GNU ddrescue runner publishes valid mapfile progress")
    func ddrescueRunnerProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalDDRescueProgress-\(UUID().uuidString)", isDirectory: true)
        let mapURL = root.appendingPathComponent("camera.img.map")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(interruptedMapfile(byteCount: 64_000).utf8).write(to: mapURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = DDRescueProgressRecorder()
        let command = DDRescueCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            currentDirectoryURL: root,
            runnerLogURL: root.appendingPathComponent("ddrescue.log"),
            mapURL: mapURL,
            sourceByteCount: 64_000
        )
        try await DDRescueRunner().image(command: command) { snapshot in
            await recorder.append(snapshot)
        }

        let snapshots = await recorder.snapshots
        #expect(!snapshots.isEmpty)
        #expect(snapshots.last?.totalByteCount == 64_000)
        #expect(snapshots.last?.rescuedByteCount == 16_000)
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

    @Test("Cancelling card imaging preserves its partial image and resume sidecars")
    func cardImagingCancellationPreservesResumeFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Data Revival Cancellation \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try #require(makeStorageDevice(bsdName: "disk7", byteCount: 64_000))
        let plan = try CardImagingPlan.prepare(
            sourceDevice: source,
            imageURL: root.appendingPathComponent("partial card image.img"),
            destinationWholeDiskBSDName: "disk2",
            availableCapacity: 128_000
        )
        let partialImage = Data(repeating: 0x5a, count: 16_000)
        let partialMap = Data(interruptedMapfile(byteCount: source.byteCount).utf8)
        try partialImage.write(to: plan.imageURL)
        try partialMap.write(to: plan.mapURL)

        let command = DDRescueCommand(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            currentDirectoryURL: root,
            runnerLogURL: plan.runnerLogURL,
            resumeRecordURL: plan.resumeRecordURL,
            resumeRecord: plan.resumeRecord,
            mapURL: plan.mapURL,
            sourceByteCount: source.byteCount
        )
        let runner = DDRescueRunner()
        let imagingTask = Task {
            try await runner.image(command: command)
        }

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: plan.runnerLogURL.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: plan.runnerLogURL.path))
        try await Task.sleep(for: .milliseconds(50))
        imagingTask.cancel()

        do {
            try await imagingTask.value
            Issue.record("Expected card imaging cancellation to throw CancellationError")
        } catch is CancellationError {
            // Expected: the runner stops its child process and reports task cancellation.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }

        #expect(try Data(contentsOf: plan.imageURL) == partialImage)
        #expect(try Data(contentsOf: plan.mapURL) == partialMap)
        #expect(FileManager.default.fileExists(atPath: plan.runnerLogURL.path))
        let record = try JSONDecoder().decode(
            CardImagingResumeRecord.self,
            from: Data(contentsOf: plan.resumeRecordURL)
        )
        #expect(record == plan.resumeRecord)
    }

    @Test("A full imaging destination is diagnosed with resumable guidance")
    func cardImagingDiagnosesFullDestination() {
        let message = ImagingFailureDiagnosis.message(
            log: "ddrescue: write error: No space left on device",
            sourceStillMatches: true,
            mapSnapshot: nil,
            exitStatus: 1
        )

        #expect(message.contains("destination ran out of space"))
        #expect(message.contains("resume files were preserved"))
    }

    @Test("A removed imaging source is diagnosed with reconnection guidance")
    func cardImagingDiagnosesRemovedSource() {
        let message = ImagingFailureDiagnosis.message(
            log: "",
            sourceStillMatches: false,
            mapSnapshot: nil,
            exitStatus: 1
        )

        #expect(message.contains("source was removed or changed"))
        #expect(message.contains("reconnect the original card"))
    }

    @Test("Unreadable imaging regions are diagnosed from the mapfile")
    func cardImagingDiagnosesReadErrors() {
        let snapshot = DDRescueMapSnapshot(
            currentPosition: 32_000,
            currentStatus: "-",
            currentPass: 1,
            rescuedByteCount: 32_000,
            badSectorByteCount: 4_000,
            pendingByteCount: 28_000
        )
        let message = ImagingFailureDiagnosis.message(
            log: "",
            sourceStillMatches: true,
            mapSnapshot: snapshot,
            exitStatus: 1
        )

        #expect(message.contains("read errors"))
        #expect(message.contains("mapfile were preserved"))
    }

    @Test("An unknown imaging-engine failure retains diagnostic guidance")
    func cardImagingDiagnosesUnknownEngineFailure() {
        let message = ImagingFailureDiagnosis.message(
            log: "unexpected engine failure",
            sourceStillMatches: true,
            mapSnapshot: nil,
            exitStatus: 9
        )

        #expect(message.contains("exit status 9"))
        #expect(message.contains("log were preserved"))
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
        let invocation = AuthopenInvocation(device: resumed.sourceDevice)
        #expect(invocation.rawDeviceURL.path == "/dev/rdisk9")
        #expect(invocation.authorizationRight == "sys.openfile.readonly./dev/rdisk9")
        let descriptorCommand = DDRescueCommand.image(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            plan: resumed,
            sourcePath: "/dev/fd/0"
        )
        #expect(descriptorCommand.arguments.contains("/dev/fd/0"))
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

        let mapfileWithRawDeviceTail = """
        0x00002800 ? 1
        0x00000000 0x00002800 +
        0x00002800 0x0000D800 ?
        0x00010000 0x7FFFFFFFFFFEFFFF ?
        """
        let clippedSnapshot = try DDRescueMapfile.parse(
            Data(mapfileWithRawDeviceTail.utf8),
            expectedByteCount: 65_536
        )
        #expect(clippedSnapshot.rescuedByteCount == 10_240)
        #expect(clippedSnapshot.pendingByteCount == 55_296)
        #expect(clippedSnapshot.totalByteCount == 65_536)

        let mapfileEndingBeforeSource = """
        0 ? 1
        0 32768 +
        """
        #expect(throws: DDRescueMapfile.ParseError.invalid) {
            try DDRescueMapfile.parse(
                Data(mapfileEndingBeforeSource.utf8),
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

    @Test("Photo scan profile enables JPEG and common camera RAW families")
    func photoScanProfileCommand() {
        let session = RecoverySession(
            id: UUID(),
            createdAt: .now,
            updatedAt: .now,
            sourceImagePath: "/Volumes/Test Images/card.dd",
            sessionDirectoryPath: "/Volumes/Recovery Drive/session",
            status: .ready,
            recoveredFiles: [],
            failureMessage: nil,
            scanProfile: .photos
        )

        let command = PhotoRecCommand.scan(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/photorec"),
            session: session,
            profile: .photos
        )

        #expect(command.arguments.last == [
            "fileopt,everything,disable",
            "jpg,enable",
            "tif,enable",
            "crw,enable",
            "orf,enable",
            "raf,enable",
            "raw,enable",
            "rw2,enable",
            "x3f,enable",
            "wholespace,search"
        ].joined(separator: ","))
    }

    @Test("Photo scan profile stays aligned with the recovery benchmark")
    func photoScanProfileMatchesBenchmark() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot
            .appendingPathComponent("Benchmarks/RecoveryQuality/v1/manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        let manifest = try #require(object as? [String: Any])
        let scanProfiles = try #require(manifest["scanProfiles"] as? [String: [String]])

        #expect(scanProfiles["jpeg"] == RecoveryScanProfile.jpeg.photoRecFileFamilies)
        #expect(scanProfiles["photos"] == RecoveryScanProfile.photos.photoRecFileFamilies)
    }

    @Test("Older session manifests default to the JPEG scan profile")
    func legacySessionScanProfile() throws {
        let session = RecoverySession(
            id: UUID(),
            createdAt: .now,
            updatedAt: .now,
            sourceImagePath: "/tmp/card.dd",
            sessionDirectoryPath: "/tmp/session",
            status: .completed,
            recoveredFiles: [],
            failureMessage: nil
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RecoverySession.self, from: data)

        #expect(decoded.scanProfile == nil)
        #expect(decoded.effectiveScanProfile == .jpeg)
        #expect(decoded.sourceIdentity == nil)
        #expect(decoded.engineProvenance == nil)
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
        session.scanProfile = .photos
        session.status = .completed
        session.updatedAt = session.createdAt.addingTimeInterval(1)
        try await store.save(session)

        let reloaded = try await RecoverySessionStore(catalogDirectory: catalog).loadAll()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == session.id)
        #expect(reloaded.first?.status == .completed)
        #expect(reloaded.first?.scanProfile == .photos)
        #expect(reloaded.first?.sourceIdentity?.byteCount == 4)
        #expect(reloaded.first?.sourceIdentity?.fileIdentifier != nil)
        #expect(abs((reloaded.first?.updatedAt.timeIntervalSince1970 ?? 0) - session.updatedAt.timeIntervalSince1970) < 1)
        #expect(FileManager.default.fileExists(atPath: session.manifestURL.path))
    }

    @Test("Session cleanup verifies and discards its managed folder and catalog entry")
    func sessionCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalCleanup-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("camera.dd")
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([0x00]).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecoverySessionStore(
            catalogDirectory: catalog,
            trashItem: { url in
                try FileManager.default.removeItem(at: url)
                return nil
            }
        )
        let session = try await store.createSession(sourceImage: source, destinationRoot: destination)
        #expect(FileManager.default.fileExists(atPath: session.sessionDirectoryURL.path))

        try await store.moveSessionToTrash(id: session.id)

        #expect(!FileManager.default.fileExists(atPath: session.sessionDirectoryURL.path))
        #expect(try await store.loadAll().isEmpty)
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
        try Data("PhotoRec report".utf8).write(to: recovered.appendingPathComponent("report.xml"))
        try Data([4]).write(to: root.appendingPathComponent("runner.log"))
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try PhotoRecRunner.collectRecoveredFiles(in: root)
        #expect(files.count == 1)
        #expect(files.first?.name == "f000001.jpg")
        #expect(files.first?.byteCount == 3)
    }

    @Test("Live scan progress counts only PhotoRec output files")
    func liveScanProgress() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalProgress-\(UUID().uuidString)", isDirectory: true)
        let recovered = root.appendingPathComponent("recovered.1", isDirectory: true)
        let unrelated = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: recovered.appendingPathComponent("f000001.jpg"))
        try Data([4, 5]).write(to: recovered.appendingPathComponent("f000002.jpg"))
        try Data("PhotoRec report".utf8).write(to: recovered.appendingPathComponent("report.xml"))
        try Data([6, 7, 8, 9]).write(to: unrelated.appendingPathComponent("not-recovered.jpg"))
        try Data([0]).write(to: root.appendingPathComponent("runner.log"))
        defer { try? FileManager.default.removeItem(at: root) }

        let startedAt = Date(timeIntervalSince1970: 100)
        let progress = RecoveryScanProgress.snapshot(
            in: root,
            startedAt: startedAt,
            now: Date(timeIntervalSince1970: 112.5)
        )

        #expect(progress.elapsedTime == 12.5)
        #expect(progress.recoveredFileCount == 2)
        #expect(progress.recoveredByteCount == 5)
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

    @Test("RAW and TIFF validation reports preview decoding without claiming full integrity")
    func rawPreviewValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataRevivalRAWValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A TIFF payload with a DNG extension exercises the TIFF-based RAW path
        // without requiring a proprietary camera fixture in the test suite.
        let rawURL = root.appendingPathComponent("complete.dng")
        try writeTestImage(to: rawURL, type: .tiff)
        let raw = RecoveredFile(
            id: UUID(),
            path: rawURL.path,
            byteCount: Int64((try Data(contentsOf: rawURL)).count),
            validationStatus: .notChecked
        )

        let corruptURL = root.appendingPathComponent("corrupt.raw")
        try Data([0, 1, 2, 3]).write(to: corruptURL)
        let corrupt = RecoveredFile(
            id: UUID(),
            path: corruptURL.path,
            byteCount: 4,
            validationStatus: .notChecked
        )

        #expect(raw.kind == .rawOrTIFF)
        #expect(RecoveredFileValidator.validate(raw).validationStatus == .previewReadable)
        #expect(RecoveredFileValidator.validate(corrupt).validationStatus == .possiblyPartial)
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
        try writeTestImage(to: url, type: .jpeg)
    }

    private func writeTestImage(to url: URL, type: UTType) throws {
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
            type.identifier as CFString,
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

private actor DDRescueProgressRecorder {
    private(set) var snapshots: [DDRescueMapSnapshot] = []

    func append(_ snapshot: DDRescueMapSnapshot) {
        snapshots.append(snapshot)
    }
}

private struct RecoveryEngineSourceLock: Decodable {
    struct Target: Decodable {
        let architecture: String
        let minimumMacOS: String
    }

    struct Engine: Decodable {
        struct Patch: Decodable {
            let fileName: String
            let sha256: String
        }

        let version: String
        let sourceArchiveName: String
        let sourceURL: URL
        let sourceSHA256: String
        let releaseURL: URL
        let license: String
        let patches: [Patch]?
    }

    let schemaVersion: Int
    let target: Target
    let engines: [String: Engine]
}

private actor RecordingDiskLifecycleController: DiskLifecycleControlling {
    private(set) var operations: [DiskLifecycleOperation] = []

    func unmountWholeDisk(bsdName: String) {
        operations.append(.unmount)
    }

    func mountWholeDisk(bsdName: String) {
        operations.append(.mount)
    }

    func ejectWholeDisk(bsdName: String) {
        operations.append(.eject)
    }
}

private final class DeviceResolutionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [StorageDevice?]
    private var count = 0

    var resolutionCount: Int {
        lock.withLock { count }
    }

    init(_ devices: [StorageDevice?]) {
        self.devices = devices
    }

    func next(bsdName: String) -> StorageDevice? {
        lock.withLock {
            count += 1
            guard !devices.isEmpty else { return nil }
            return devices.removeFirst()
        }
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

private func sendFileDescriptor(_ descriptor: Int32, to socket: Int32) throws {
    var payload: UInt8 = 0
    var control = [UInt8](
        repeating: 0,
        count: MemoryLayout<cmsghdr>.stride + MemoryLayout<Int32>.stride
    )
    var message = msghdr()

    let sent = withUnsafeMutableBytes(of: &payload) { payloadBytes in
        var vector = iovec(iov_base: payloadBytes.baseAddress, iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
            message.msg_iov = vectorPointer
            message.msg_iovlen = 1
            return control.withUnsafeMutableBytes { controlBytes in
                guard let baseAddress = controlBytes.baseAddress else { return -1 }
                let header = baseAddress.assumingMemoryBound(to: cmsghdr.self)
                header.pointee.cmsg_len = socklen_t(
                    MemoryLayout<cmsghdr>.stride + MemoryLayout<Int32>.size
                )
                header.pointee.cmsg_level = SOL_SOCKET
                header.pointee.cmsg_type = SCM_RIGHTS
                baseAddress
                    .advanced(by: MemoryLayout<cmsghdr>.stride)
                    .storeBytes(of: descriptor, as: Int32.self)
                message.msg_control = baseAddress
                message.msg_controllen = socklen_t(controlBytes.count)
                return sendmsg(socket, &message, 0)
            }
        }
    }
    guard sent == 1 else { throw CocoaError(.fileWriteUnknown) }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
