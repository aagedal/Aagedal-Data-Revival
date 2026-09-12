import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

@main
struct DataRevivalApp: App {
    var body: some Scene {
        WindowGroup("Data Revival") {
            RecoveryView()
                .frame(minWidth: 960, minHeight: 650)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1180, height: 780)
    }
}

private enum Workspace: String, CaseIterable, Identifiable {
    case recover = "Recover files"
    case sessions = "Recovery sessions"
    case tools = "Disk tools"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .recover: "arrow.counterclockwise"
        case .sessions: "clock"
        case .tools: "externaldrive"
        }
    }
}

private struct SampleFile: Identifiable {
    let id: Int
    let name: String
    let kind: String
    let size: String
    let status: String
    var symbol: String { kind == "Video" ? "film" : "photo" }
    static let examples: [SampleFile] = [
        .init(id: 1, name: "Recovered_0001.JPG", kind: "JPEG", size: "12.4 MB", status: "Preview available"),
        .init(id: 2, name: "Recovered_0002.CR3", kind: "RAW", size: "28.6 MB", status: "Needs validation"),
        .init(id: 3, name: "Recovered_0003.JPG", kind: "JPEG", size: "10.8 MB", status: "Preview available"),
        .init(id: 4, name: "Recovered_0004.MP4", kind: "Video", size: "482 MB", status: "Possibly partial")
    ]
}

private struct RecoveryView: View {
    @StateObject private var recovery = RecoveryViewModel()
    @StateObject private var diskDevices = DiskDeviceMonitor()
    @State private var workspace: Workspace? = .recover
    @State private var imageURL: URL?
    @State private var showingDemo = false
    @State private var selection: Int?
    @State private var recoveredSelection: Set<UUID> = []
    @State private var sessionSelection: UUID?
    @State private var filter = "All files"
    @State private var query = ""
    @State private var issue: String?
    @State private var exportConfirmation: String?
    @State private var diskSelection: String?
    @State private var preparedImagingPlan: CardImagingPlan?

    private var files: [SampleFile] {
        SampleFile.examples.filter {
            (filter == "All files" || $0.kind == filter) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 32)).foregroundStyle(.teal)
                    VStack(alignment: .leading) {
                        Text("Data Revival").font(.headline)
                        Text("AAGEDAL").font(.caption2).tracking(2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12).padding(.top, 18)
                List(Workspace.allCases, selection: $workspace) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Early prototype", systemImage: "hammer").font(.callout.weight(.medium))
                    Text("Explore sample files or run an experimental JPEG scan from a raw disk image.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 270)
        } detail: {
            Group {
                switch workspace ?? .recover {
                case .recover: recoveryContent
                case .sessions: sessionsContent
                case .tools: diskToolsContent
                }
            }
            .navigationTitle(workspace?.rawValue ?? "Recover files")
            .toolbar {
                ToolbarItem {
                    Text("PROTOTYPE").font(.caption2.weight(.semibold)).tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.orange.opacity(0.12), in: Capsule()).foregroundStyle(.orange)
                }
            }
        }
        .tint(.teal)
        .task { recovery.loadSessions() }
        .onChange(of: workspace) { _, workspace in
            if workspace == .tools {
                diskDevices.start()
            } else {
                diskDevices.stop()
                diskSelection = nil
                preparedImagingPlan = nil
            }
        }
        .alert("Recovery could not continue", isPresented: Binding(
            get: { issue != nil || recovery.errorMessage != nil },
            set: {
                if !$0 {
                    issue = nil
                    recovery.errorMessage = nil
                }
            }
        )) {
            Button("OK") {
                issue = nil
                recovery.errorMessage = nil
            }
        } message: { Text(issue ?? recovery.errorMessage ?? "Unknown error") }
        .alert("Export complete", isPresented: Binding(
            get: { exportConfirmation != nil },
            set: { if !$0 { exportConfirmation = nil } }
        )) {
            Button("OK") { exportConfirmation = nil }
        } message: {
            Text(exportConfirmation ?? "The selected files were exported.")
        }
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                step("1", "Choose source", active: !showingDemo && recovery.activeSession == nil)
                Rectangle().fill(.quaternary).frame(height: 1)
                step("2", "Scan image", active: recovery.isScanning)
                Rectangle().fill(.quaternary).frame(height: 1)
                step("3", "Review files", active: showingDemo || (recovery.activeSession != nil && !recovery.isScanning))
            }
            if showingDemo {
                results
            } else if recovery.activeSession != nil {
                liveRecoveryContent
            } else {
                source
            }
        }.padding(32)
    }

    private func step(_ number: String, _ title: String, active: Bool) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.caption.weight(.semibold)).frame(width: 25, height: 25)
                .background(active ? Color.teal.opacity(0.16) : Color.secondary.opacity(0.1), in: Circle())
            Text(title).font(.callout.weight(active ? .semibold : .regular))
        }.foregroundStyle(active ? Color.primary : Color.secondary).fixedSize()
    }

    private var source: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bring your work back.").font(.system(size: 34, weight: .semibold))
                    Text("A calmer way to recover photos and footage from a formatted camera card.")
                        .font(.title3).foregroundStyle(.secondary)
                }.padding(.top, 22)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "sdcard").font(.system(size: 35)).foregroundStyle(.teal)
                        Text("Camera card").font(.title2.weight(.semibold))
                        Text("Create a complete image of your card, then recover files from the copy.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Label("Device imaging is planned", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "doc.zipper").font(.system(size: 35)).foregroundStyle(.teal)
                        Text("Disk image").font(.title2.weight(.semibold))
                        Text("Choose an existing raw image to prepare a recovery session.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose image…", action: chooseImage).buttonStyle(.borderedProminent)
                    }.padding(24).frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
                        .background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                }
                if let imageURL {
                    HStack(spacing: 12) {
                        Image(systemName: "doc").font(.title2).foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(imageURL.lastPathComponent).font(.headline)
                            Text("Ready for an experimental read-only JPEG scan.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack {
                            Button("Remove") { self.imageURL = nil }
                            Button("Recover JPEGs…", action: chooseDestinationAndScan)
                                .buttonStyle(.borderedProminent)
                        }
                    }.padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
                Label("Keep the original card untouched. Save images and recovered files to another drive.", systemImage: "externaldrive.badge.checkmark")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Take a look around").font(.headline)
                        Text("Explore the review screen using four sample files.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Explore sample results") { showingDemo = true }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var liveRecoveryContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if recovery.isScanning {
                Spacer()
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text("Scanning the disk image").font(.title2.weight(.semibold))
                    Text("PhotoRec is looking for JPEG files. Recovered data is written directly to the session folder.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                    Button("Cancel scan") { recovery.cancelScan() }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if let session = recovery.activeSession {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.status == .completed ? "Recovered files" : "Recovery stopped")
                            .font(.system(size: 28, weight: .semibold))
                        Text(liveSessionSummary(session))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose another image") {
                        recovery.dismissActiveSession()
                        recoveredSelection.removeAll()
                    }
                }

                if recovery.recoveredFiles.isEmpty {
                    ContentUnavailableView(
                        session.status == .completed ? "No JPEG files found" : "No results available",
                        systemImage: session.status == .completed ? "photo.badge.magnifyingglass" : "exclamationmark.triangle",
                        description: Text(session.failureMessage ?? "The session folder and process logs have been preserved.")
                    )
                } else {
                    HStack {
                        Text(recoveredSelection.isEmpty
                             ? "Select files to preview or export"
                             : "\(recoveredSelection.count) selected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Export Selected…", action: chooseExportDestination)
                            .disabled(recoveredSelection.isEmpty)
                    }
                    Table(recovery.recoveredFiles, selection: $recoveredSelection) {
                        TableColumn("Name") { file in
                            Label(file.name, systemImage: "photo")
                        }.width(min: 220, ideal: 300)
                        TableColumn("Type") { file in Text(file.fileExtension) }.width(60)
                        TableColumn("Size") { file in Text(file.byteCount.formatted(.byteCount(style: .file))) }.width(90)
                        TableColumn("Validation") { file in Text(validationLabel(file.validationStatus)) }
                    }
                    if recoveredSelection.count == 1,
                       let file = recovery.recoveredFiles.first(where: { recoveredSelection.contains($0.id) }) {
                        recoveredFileInspector(file)
                    }
                    Text("Basic validation decodes each JPEG and checks for an end marker. Even a readable result may contain localized image damage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionsContent: some View {
        Group {
            if recovery.sessions.isEmpty {
                ContentUnavailableView(
                    "No recovery sessions yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sessions will appear here after you start a scan.")
                )
            } else {
                List(recovery.sessions, selection: $sessionSelection) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(session.sourceImageURL.lastPathComponent).font(.headline)
                            Spacer()
                            Text(session.status.rawValue.capitalized)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(sessionStatusColor(session.status))
                        }
                        Text("\(session.recoveredFiles.count) files • \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(session.sessionDirectoryPath)
                            .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .tag(session.id)
                }
                .onChange(of: sessionSelection) { _, id in
                    guard let id else { return }
                    recovery.openSession(id: id)
                    recoveredSelection.removeAll()
                    workspace = .recover
                    sessionSelection = nil
                }
            }
        }
    }

    private var diskToolsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connected removable media")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Read-only discovery shows removable and external whole disks reported by macOS.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rescan", systemImage: "arrow.clockwise") {
                    diskDevices.restart()
                }
            }

            if let message = diskDevices.errorMessage {
                ContentUnavailableView(
                    "Disk discovery unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(message)
                )
            } else if diskDevices.devices.isEmpty {
                ContentUnavailableView(
                    "No removable media found",
                    systemImage: "sdcard",
                    description: Text("Connect an SD, microSD, CFexpress, or external storage device, then choose Rescan.")
                )
            } else {
                List(diskDevices.devices, selection: $diskSelection) { device in
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.fill")
                            .font(.title2)
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.displayName).font(.headline)
                            Text(deviceSummary(device))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.devicePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .tag(device.id)
                }

                if let id = diskSelection,
                   let device = diskDevices.devices.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Source protection", systemImage: "lock.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.teal)
                        Text("\(device.displayName) will be opened read-only. Imaging will require an unmounted card and a destination on a different physical device.")
                            .foregroundStyle(.secondary)
                        if let plan = preparedImagingPlan, plan.sourceDevice.id == device.id {
                            Label(
                                imagingPlanSummary(plan),
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.callout)
                            .foregroundStyle(.green)
                        }
                        HStack {
                            Button("Check imaging destination…") {
                                chooseCardImageDestination(for: device)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Check existing image for resume…") {
                                chooseCardImageToResume(for: device)
                            }
                            Button("Start imaging") {}
                                .disabled(true)
                                .help("A narrowly scoped privileged helper and safe unmount flow are still required before raw-device imaging can start.")
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Label(
                "Discovery does not mount, unmount, eject, or write to any device.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .onAppear { diskDevices.start() }
        .onDisappear { diskDevices.stop() }
        .onChange(of: diskSelection) { _, _ in
            preparedImagingPlan = nil
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A second look at your files.").font(.system(size: 28, weight: .semibold))
                    Text("Sample results • No card was scanned • No files were recovered")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Back to source") { showingDemo = false; selection = nil }
            }
            HStack {
                Picker("Type", selection: $filter) {
                    ForEach(["All files", "JPEG", "RAW", "Video"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 350)
                Spacer()
                TextField("Search sample files", text: $query).textFieldStyle(.roundedBorder).frame(width: 210)
            }
            Table(files, selection: $selection) {
                TableColumn("Name") { file in Label(file.name, systemImage: file.symbol) }.width(min: 220, ideal: 260)
                TableColumn("Type", value: \.kind).width(55)
                TableColumn("Size", value: \.size).width(70)
                TableColumn("Status", value: \.status)
            }
            if let selected = SampleFile.examples.first(where: { $0.id == selection }) {
                HStack(spacing: 16) {
                    Image(systemName: selected.symbol).font(.largeTitle).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selected.name).font(.headline)
                        Text("Illustrative metadata only. Run a disk-image scan to generate real files and session details.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("A preview does not guarantee a complete file. Fragmented camera video may need specialized recovery.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a raw disk image"
        panel.message = "Select a nonempty IMG, DD, or RAW file. The source will be treated as read-only."
        panel.allowedContentTypes = ["img", "dd", "raw"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                issue = "Choose a nonempty regular disk-image file."
                return
            }
            imageURL = url
        } catch { issue = error.localizedDescription }
    }

    private func chooseCardImageDestination(for device: StorageDevice) {
        let panel = NSSavePanel()
        panel.title = "Choose card image destination"
        panel.message = "Save the image on a different physical device. No file will be created during this safety check."
        panel.nameFieldStringValue = "\(device.displayName).img"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let imageType = UTType(filenameExtension: "img") {
            panel.allowedContentTypes = [imageType]
        }
        guard panel.runModal() == .OK, let imageURL = panel.url else { return }

        do {
            let destinationDirectory = imageURL.deletingLastPathComponent()
            let destinationDisk = try DiskIdentityResolver.wholeDiskBSDName(
                containing: destinationDirectory
            )
            let capacity = try destinationDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
            let plan = try CardImagingPlan.prepare(
                sourceDevice: device,
                imageURL: imageURL,
                destinationWholeDiskBSDName: destinationDisk,
                availableCapacity: capacity
            )
            try plan.validateCurrentSource(
                DiskIdentityResolver.currentDevice(bsdName: device.bsdName)
            )
            preparedImagingPlan = plan
        } catch {
            preparedImagingPlan = nil
            issue = error.localizedDescription
        }
    }

    private func chooseCardImageToResume(for device: StorageDevice) {
        let panel = NSOpenPanel()
        panel.title = "Choose an interrupted card image"
        panel.message = "Choose the IMG file beside its .map and .datarevival.json sidecars. Data Revival will verify the original card identity and remaining free space."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let imageType = UTType(filenameExtension: "img") {
            panel.allowedContentTypes = [imageType]
        }
        guard panel.runModal() == .OK, let imageURL = panel.url else { return }

        do {
            let destinationDirectory = imageURL.deletingLastPathComponent()
            let destinationDisk = try DiskIdentityResolver.wholeDiskBSDName(
                containing: destinationDirectory
            )
            let capacity = try destinationDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
            let plan = try CardImagingPlan.prepareResume(
                sourceDevice: device,
                imageURL: imageURL,
                destinationWholeDiskBSDName: destinationDisk,
                availableCapacity: capacity
            )
            try plan.validateCurrentSource(
                DiskIdentityResolver.currentDevice(bsdName: device.bsdName)
            )
            preparedImagingPlan = plan
        } catch {
            preparedImagingPlan = nil
            issue = error.localizedDescription
        }
    }

    private func chooseDestinationAndScan() {
        guard let imageURL else { return }
        guard let executableURL = PhotoRecExecutableLocator.locate() else {
            issue = "PhotoRec is not installed. Install TestDisk/PhotoRec with Homebrew for development, or add a bundled photorec executable before scanning."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose recovery destination"
        panel.message = "Choose a folder with enough free space. Data Revival will create a new isolated session folder here."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        showingDemo = false
        recovery.startJPEGScan(
            sourceImage: imageURL,
            destinationRoot: destination,
            executableURL: executableURL
        )
    }

    private func chooseExportDestination() {
        guard !recoveredSelection.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export recovered files"
        panel.message = "Choose a folder for the selected files. Existing files will not be overwritten."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let selectedIDs = recoveredSelection
        Task {
            do {
                let exported = try await recovery.exportFiles(ids: selectedIDs, to: destination)
                exportConfirmation = "Exported \(exported.count) file\(exported.count == 1 ? "" : "s") to \(destination.lastPathComponent)."
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func recoveredFileInspector(_ file: RecoveredFile) -> some View {
        HStack(spacing: 18) {
            QuickLookFilePreview(url: file.url)
                .frame(width: 220, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                Text(file.name).font(.headline)
                Text(file.byteCount.formatted(.byteCount(style: .file)))
                Label(validationLabel(file.validationStatus), systemImage: validationSymbol(file.validationStatus))
                    .foregroundStyle(file.validationStatus == .readable ? .green : .orange)
                Text("Readable means the image decoded and contained an end marker. It does not guarantee that every pixel is undamaged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func liveSessionSummary(_ session: RecoverySession) -> String {
        switch session.status {
        case .ready: "Ready to scan"
        case .scanning: "Scanning \(session.sourceImageURL.lastPathComponent)"
        case .completed: "\(session.recoveredFiles.count) JPEG files found in \(session.sourceImageURL.lastPathComponent)"
        case .cancelled: "The scan was cancelled. Partial output was preserved."
        case .interrupted: "The app stopped before the scan finished. Partial output was preserved."
        case .failed: session.failureMessage ?? "The scan failed."
        }
    }

    private func imagingPlanSummary(_ plan: CardImagingPlan) -> String {
        switch plan.mode {
        case .create:
            "\(plan.imageURL.lastPathComponent) passed the physical-device, collision, and free-space checks."
        case .resume:
            "\(plan.imageURL.lastPathComponent) matches this card and has a usable ddrescue mapfile and enough remaining space."
        }
    }

    private func sessionStatusColor(_ status: RecoverySession.Status) -> Color {
        switch status {
        case .failed: .red
        case .cancelled, .interrupted: .orange
        case .ready, .scanning, .completed: .secondary
        }
    }

    private func validationLabel(_ status: RecoveredFile.ValidationStatus) -> String {
        switch status {
        case .notChecked: "Not checked"
        case .readable: "Readable"
        case .possiblyPartial: "Possibly partial"
        }
    }

    private func validationSymbol(_ status: RecoveredFile.ValidationStatus) -> String {
        switch status {
        case .notChecked: "questionmark.circle"
        case .readable: "checkmark.circle.fill"
        case .possiblyPartial: "exclamationmark.triangle.fill"
        }
    }

    private func deviceSummary(_ device: StorageDevice) -> String {
        var parts: [String] = []
        if device.byteCount > 0 {
            parts.append(device.byteCount.formatted(.byteCount(style: .file)))
        }
        if let connection = device.connectionProtocol, !connection.isEmpty {
            parts.append(connection)
        }
        if device.isRemovable {
            parts.append("Removable")
        } else if device.isEjectable {
            parts.append("Ejectable")
        } else {
            parts.append("External")
        }
        return parts.joined(separator: " • ")
    }
}

private struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.autostarts = true
        preview.previewItem = url as NSURL
        return preview
    }

    func updateNSView(_ preview: QLPreviewView, context: Context) {
        preview.previewItem = url as NSURL
        preview.refreshPreviewItem()
    }
}
