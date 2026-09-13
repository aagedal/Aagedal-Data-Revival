import SwiftUI
import AppKit
import QuickLookUI
import ServiceManagement
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
    var symbol: String { kind == "RAW" ? "camera.aperture" : "photo" }
    static let examples: [SampleFile] = [
        .init(id: 1, name: "Recovered_0001.JPG", kind: "JPEG", size: "12.4 MB", status: "Preview available"),
        .init(id: 2, name: "Recovered_0002.CR3", kind: "RAW", size: "28.6 MB", status: "Needs validation"),
        .init(id: 3, name: "Recovered_0003.JPG", kind: "JPEG", size: "10.8 MB", status: "Preview available")
    ]
}

private enum RecoveredFileFilter: String, CaseIterable, Identifiable {
    case all = "All files"
    case jpeg = "JPEG"
    case rawOrTIFF = "RAW / TIFF"
    case needsReview = "Needs review"

    var id: String { rawValue }

    func includes(_ file: RecoveredFile) -> Bool {
        switch self {
        case .all:
            true
        case .jpeg:
            file.kind == .jpeg
        case .rawOrTIFF:
            file.kind == .rawOrTIFF
        case .needsReview:
            file.validationStatus == .notChecked || file.validationStatus == .possiblyPartial
        }
    }
}

private struct RecoveryView: View {
    @StateObject private var recovery = RecoveryViewModel()
    @StateObject private var diskDevices = DiskDeviceMonitor()
    @StateObject private var imaging = CardImagingViewModel()
    @State private var workspace: Workspace? = .recover
    @State private var imageURL: URL?
    @State private var scanProfile: RecoveryScanProfile = .photos
    @State private var showingDemo = false
    @State private var selection: Int?
    @State private var recoveredSelection: Set<UUID> = []
    @State private var recoveredFilter: RecoveredFileFilter = .all
    @State private var recoveredQuery = ""
    @State private var sessionSelection: UUID?
    @State private var filter = "All files"
    @State private var query = ""
    @State private var issue: String?
    @State private var exportConfirmation: String?
    @State private var diskSelection: String?
    @State private var preparedImagingPlan: CardImagingPlan?
    @State private var sessionPendingRemoval: RecoverySession?

    private var files: [SampleFile] {
        SampleFile.examples.filter {
            (filter == "All files" || $0.kind == filter) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    private var visibleRecoveredFiles: [RecoveredFile] {
        recovery.recoveredFiles.filter { file in
            recoveredFilter.includes(file) &&
            (recoveredQuery.isEmpty || file.name.localizedCaseInsensitiveContains(recoveredQuery))
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
                }
                .listStyle(.sidebar)
                .disabled(imaging.isActive)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Early prototype", systemImage: "hammer").font(.callout.weight(.medium))
                    Text("Explore sample files or run an experimental photo scan from a raw disk image.")
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
        .task {
            recovery.loadSessions()
            imaging.refreshHelperStatus()
        }
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
            get: { issue != nil || recovery.errorMessage != nil || imagingFailureMessage != nil },
            set: {
                if !$0 {
                    issue = nil
                    recovery.errorMessage = nil
                    imaging.clearFailure()
                }
            }
        )) {
            Button("OK") {
                issue = nil
                recovery.errorMessage = nil
                imaging.clearFailure()
            }
        } message: {
            Text(issue ?? recovery.errorMessage ?? imagingFailureMessage ?? "Unknown error")
        }
        .alert("Export complete", isPresented: Binding(
            get: { exportConfirmation != nil },
            set: { if !$0 { exportConfirmation = nil } }
        )) {
            Button("OK") { exportConfirmation = nil }
        } message: {
            Text(exportConfirmation ?? "The selected files were exported.")
        }
        .alert("Move recovery session to Trash?", isPresented: Binding(
            get: { sessionPendingRemoval != nil },
            set: { if !$0 { sessionPendingRemoval = nil } }
        )) {
            Button("Cancel", role: .cancel) { sessionPendingRemoval = nil }
            Button("Move to Trash", role: .destructive) {
                if let session = sessionPendingRemoval {
                    recovery.moveSessionToTrash(id: session.id)
                }
                sessionPendingRemoval = nil
            }
        } message: {
            Text("Recovered output, logs, and the manifest in this session folder will be moved to the Trash. The source disk image will remain untouched.")
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

    private func scanMetric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 90)
    }

    private func formattedElapsedTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    private var source: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bring your work back.").font(.system(size: 34, weight: .semibold))
                    Text("A calmer way to recover photos from a formatted camera card.")
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
                            Text("Ready for an experimental read-only photo scan.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("File types", selection: $scanProfile) {
                            ForEach(RecoveryScanProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .help(scanProfile.shortDescription)
                        HStack {
                            Button("Remove") { self.imageURL = nil }
                            Button(
                                scanProfile == .jpeg ? "Recover JPEGs…" : "Recover Photos…",
                                action: chooseDestinationAndScan
                            )
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
                        Text("Explore the review screen using three sample files.").foregroundStyle(.secondary)
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
                    Text(
                        "PhotoRec is looking for \(recovery.activeSession?.effectiveScanProfile.resultDescription ?? "photo files"). "
                        + "Recovered data is written directly to the session folder."
                    )
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                    if let progress = recovery.scanProgress {
                        HStack(spacing: 24) {
                            scanMetric(
                                value: progress.recoveredFileCount.formatted(),
                                label: "files found"
                            )
                            scanMetric(
                                value: progress.recoveredByteCount.formatted(.byteCount(style: .file)),
                                label: "written"
                            )
                            scanMetric(
                                value: formattedElapsedTime(progress.elapsedTime),
                                label: "elapsed"
                            )
                        }
                        .padding(.vertical, 4)
                    }
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
                        recoveredFilter = .all
                        recoveredQuery = ""
                    }
                }

                if recovery.recoveredFiles.isEmpty {
                    ContentUnavailableView(
                        session.status == .completed
                            ? "No \(session.effectiveScanProfile.resultDescription) found"
                            : "No results available",
                        systemImage: session.status == .completed ? "photo.badge.magnifyingglass" : "exclamationmark.triangle",
                        description: Text(session.failureMessage ?? "The session folder and process logs have been preserved.")
                    )
                } else {
                    HStack {
                        Picker("Type", selection: $recoveredFilter) {
                            ForEach(RecoveredFileFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        Spacer()
                        TextField("Search recovered files", text: $recoveredQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    HStack {
                        Text(recoveredResultsSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Export Selected…", action: chooseExportDestination)
                            .disabled(recoveredSelection.isEmpty)
                    }
                    Table(visibleRecoveredFiles, selection: $recoveredSelection) {
                        TableColumn("Name") { file in
                            Label(file.name, systemImage: file.kind.systemImage)
                        }.width(min: 220, ideal: 300)
                        TableColumn("Type") { file in Text(file.fileExtension) }.width(60)
                        TableColumn("Size") { file in Text(file.byteCount.formatted(.byteCount(style: .file))) }.width(90)
                        TableColumn("Validation") { file in Text(validationLabel(file.validationStatus)) }
                    }
                    if recoveredSelection.count == 1,
                       let file = recovery.recoveredFiles.first(where: { recoveredSelection.contains($0.id) }) {
                        recoveredFileInspector(file)
                    }
                    Text("JPEG validation performs a full decode and checks for an end marker. RAW / TIFF validation checks whether macOS can decode a preview; unsupported formats remain not checked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: recoveredFilter) { _, _ in recoveredSelection.removeAll() }
        .onChange(of: recoveredQuery) { _, _ in recoveredSelection.removeAll() }
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
                        Text("\(session.effectiveScanProfile.displayName) • \(session.recoveredFiles.count) files • \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(session.sessionDirectoryPath)
                            .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .tag(session.id)
                    .contextMenu {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([session.sessionDirectoryURL])
                        }
                        Divider()
                        Button("Move to Trash", systemImage: "trash", role: .destructive) {
                            sessionPendingRemoval = session
                        }
                    }
                }
                .onChange(of: sessionSelection) { _, id in
                    guard let id else { return }
                    recovery.openSession(id: id)
                    recoveredSelection.removeAll()
                    recoveredFilter = .all
                    recoveredQuery = ""
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
                .disabled(imaging.isActive)

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
                        imagingControls(for: device)
                        if let snapshot = imaging.progress,
                           imaging.activePlan?.sourceDevice.id == device.id {
                            ProgressView(
                                value: Double(snapshot.rescuedByteCount),
                                total: Double(snapshot.totalByteCount)
                            )
                            Text(imagingProgressSummary(snapshot))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

            recoveryEngineStatus
        }
        .padding(32)
        .onAppear { diskDevices.start() }
        .onDisappear { diskDevices.stop() }
        .onChange(of: diskSelection) { _, _ in
            if !imaging.isActive {
                preparedImagingPlan = nil
            }
        }
    }

    @ViewBuilder
    private func imagingControls(for device: StorageDevice) -> some View {
        switch imaging.state {
        case .preparing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Authorizing, unmounting, and revalidating the card…")
                Spacer()
                Button("Cancel") { imaging.cancel() }
            }
        case .imaging:
            HStack {
                ProgressView().controlSize(.small)
                Text("Creating a resumable card image…")
                Spacer()
                Button("Cancel") { imaging.cancel() }
            }
        case .cancelling:
            HStack {
                ProgressView().controlSize(.small)
                Text("Stopping safely and preserving resume files…")
            }
        case .completed:
            VStack(alignment: .leading, spacing: 10) {
                Label("Card imaging completed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Choose whether macOS should remount the card or eject it. The completed image is ready to scan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Remount card") { imaging.finish(.remount) }
                        .buttonStyle(.borderedProminent)
                    Button("Eject card") { imaging.finish(.eject) }
                    if let plan = imaging.activePlan {
                        Button("Show image in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([plan.imageURL])
                        }
                    }
                }
            }
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 10) {
                if imaging.helperStatus == .enabled {
                    HStack {
                        Button("Check imaging destination…") {
                            chooseCardImageDestination(for: device)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Check existing image for resume…") {
                            chooseCardImageToResume(for: device)
                        }
                        Button("Start imaging") {
                            if let plan = preparedImagingPlan {
                                imaging.start(plan: plan)
                            }
                        }
                        .disabled(preparedImagingPlan?.sourceDevice.id != device.id)
                    }
                } else if imaging.helperStatus == .requiresApproval {
                    HStack {
                        Button("Open Login Items Settings") {
                            imaging.openHelperApprovalSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Check approval") { imaging.refreshHelperStatus() }
                    }
                    Text("An administrator must allow the Data Revival helper under Login Items & Extensions before the card can be imaged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Install imaging helper") {
                            do {
                                try imaging.installHelper()
                            } catch {
                                issue = error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Refresh") { imaging.refreshHelperStatus() }
                    }
                    Text("The helper opens only the selected raw card read-only and runs the bundled imaging engine after administrator approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            let capacity = try RecoveryVolumeCapacity.available(at: destinationDirectory)
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
            let capacity = try RecoveryVolumeCapacity.available(at: destinationDirectory)
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
        guard let installation = RecoveryToolLocator.locate(.photoRec) else {
            issue = RecoveryToolLocator.unavailableMessage(for: .photoRec)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose recovery destination"
        let sourceSize = (try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        let outputEstimate = RecoveryStorageEstimate(sourceByteCount: sourceSize)
            .recoveredOutputByteCount
            .formatted(.byteCount(style: .file))
        panel.message = "Choose a folder with at least \(outputEstimate) available for recovered output. Data Revival will create a new isolated session folder here."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        showingDemo = false
        recovery.startScan(
            sourceImage: imageURL,
            destinationRoot: destination,
            installation: installation,
            profile: scanProfile
        )
    }

    private var recoveryEngineStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recovery engines", systemImage: "shippingbox")
                .font(.headline)
            ForEach(RecoveryTool.allCases) { tool in
                let installation = RecoveryToolLocator.locate(tool)
                HStack {
                    Image(systemName: installation == nil ? "xmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(installation == nil ? .orange : .green)
                    Text(tool.displayName)
                    Spacer()
                    Text(engineOriginLabel(installation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(RecoveryToolLocator.allowsDevelopmentFallback
                 ? "This debug build may use package-manager installations. Release builds accept only engines shipped inside the signed app."
                 : "This release build uses only engines shipped inside the signed app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func engineOriginLabel(_ installation: RecoveryToolInstallation?) -> String {
        switch installation?.origin {
        case .appBundle: "Bundled"
        case .developmentInstall: "Development install"
        case nil: "Unavailable"
        }
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
                    .foregroundStyle(
                        file.validationStatus == .readable || file.validationStatus == .previewReadable
                            ? .green : .orange
                    )
                Text(validationExplanation(for: file))
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
        case .completed: "\(session.recoveredFiles.count) \(session.effectiveScanProfile.resultDescription) found in \(session.sourceImageURL.lastPathComponent)"
        case .cancelled: "The scan was cancelled. Partial output was preserved."
        case .interrupted: "The app stopped before the scan finished. Partial output was preserved."
        case .failed: session.failureMessage ?? "The scan failed."
        }
    }

    private func imagingPlanSummary(_ plan: CardImagingPlan) -> String {
        switch plan.mode {
        case .create:
            let total = RecoveryStorageEstimate(sourceByteCount: plan.sourceDevice.byteCount)
                .completeWorkflowByteCount
                .formatted(.byteCount(style: .file))
            return "\(plan.imageURL.lastPathComponent) passed the image checks. Plan up to \(total) across the card image and recovered output."
        case .resume:
            if let snapshot = plan.mapSnapshot {
                let rescued = snapshot.rescuedByteCount.formatted(.byteCount(style: .file))
                let percent = snapshot.rescuedFraction.formatted(
                    .percent.precision(.fractionLength(0...1))
                )
                let badSectors = snapshot.badSectorByteCount == 0
                    ? "no confirmed bad sectors"
                    : "\(snapshot.badSectorByteCount.formatted(.byteCount(style: .file))) marked as bad sectors"
                return "\(plan.imageURL.lastPathComponent) matches this card: \(rescued) rescued (\(percent)), \(badSectors), with enough space to resume."
            }
            return "\(plan.imageURL.lastPathComponent) matches this card and has enough space to resume."
        }
    }

    private var imagingFailureMessage: String? {
        guard case let .failed(message) = imaging.state else { return nil }
        return message
    }

    private func imagingProgressSummary(_ snapshot: DDRescueMapSnapshot) -> String {
        let rescued = snapshot.rescuedByteCount.formatted(.byteCount(style: .file))
        let pending = snapshot.pendingByteCount.formatted(.byteCount(style: .file))
        let bad = snapshot.badSectorByteCount.formatted(.byteCount(style: .file))
        return "\(rescued) rescued • \(pending) pending • \(bad) in bad-sector regions"
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
        case .previewReadable: "Preview readable"
        case .possiblyPartial: "Possibly partial"
        }
    }

    private func validationSymbol(_ status: RecoveredFile.ValidationStatus) -> String {
        switch status {
        case .notChecked: "questionmark.circle"
        case .readable: "checkmark.circle.fill"
        case .previewReadable: "eye.circle.fill"
        case .possiblyPartial: "exclamationmark.triangle.fill"
        }
    }

    private var recoveredResultsSummary: String {
        if !recoveredSelection.isEmpty {
            return "\(recoveredSelection.count) selected"
        }
        if visibleRecoveredFiles.count == recovery.recoveredFiles.count {
            return "\(recovery.recoveredFiles.count) files"
        }
        return "\(visibleRecoveredFiles.count) of \(recovery.recoveredFiles.count) files"
    }

    private func validationExplanation(for file: RecoveredFile) -> String {
        switch file.validationStatus {
        case .readable:
            "The JPEG decoded fully and contains an end marker. Localized image damage may still be present."
        case .previewReadable:
            "macOS decoded a preview from this RAW / TIFF file. This does not prove that the full sensor data is intact."
        case .possiblyPartial:
            "The file could not be decoded completely and may be truncated or damaged."
        case .notChecked:
            "This format could not be validated on this Mac. The file has been kept for review or export."
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
