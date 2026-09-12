import SwiftUI
import AppKit
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
    @State private var workspace: Workspace? = .recover
    @State private var imageURL: URL?
    @State private var showingDemo = false
    @State private var selection: Int?
    @State private var recoveredSelection: UUID?
    @State private var filter = "All files"
    @State private var query = ""
    @State private var issue: String?

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
                case .tools:
                    ContentUnavailableView("A safer starting point", systemImage: "externaldrive.badge.shield.checkmark", description: Text("Planned tools: create a card image, resume interrupted imaging, and inspect disk information."))
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
                        recoveredSelection = nil
                    }
                }

                if recovery.recoveredFiles.isEmpty {
                    ContentUnavailableView(
                        session.status == .completed ? "No JPEG files found" : "No results available",
                        systemImage: session.status == .completed ? "photo.badge.magnifyingglass" : "exclamationmark.triangle",
                        description: Text(session.failureMessage ?? "The session folder and process logs have been preserved.")
                    )
                } else {
                    Table(recovery.recoveredFiles, selection: $recoveredSelection) {
                        TableColumn("Name") { file in
                            Label(file.name, systemImage: "photo")
                        }.width(min: 220, ideal: 300)
                        TableColumn("Type") { file in Text(file.fileExtension) }.width(60)
                        TableColumn("Size") { file in Text(file.byteCount.formatted(.byteCount(style: .file))) }.width(90)
                        TableColumn("Validation") { file in Text(validationLabel(file.validationStatus)) }
                    }
                    Text("Found files have not been fully validated yet. A readable header does not prove that an entire photo is intact.")
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
                List(recovery.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(session.sourceImageURL.lastPathComponent).font(.headline)
                            Spacer()
                            Text(session.status.rawValue.capitalized)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(session.status == .failed ? .red : .secondary)
                        }
                        Text("\(session.recoveredFiles.count) files • \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(session.sessionDirectoryPath)
                            .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .padding(.vertical, 6)
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

    private func liveSessionSummary(_ session: RecoverySession) -> String {
        switch session.status {
        case .ready: "Ready to scan"
        case .scanning: "Scanning \(session.sourceImageURL.lastPathComponent)"
        case .completed: "\(session.recoveredFiles.count) JPEG files found in \(session.sourceImageURL.lastPathComponent)"
        case .cancelled: "The scan was cancelled. Partial output was preserved."
        case .failed: session.failureMessage ?? "The scan failed."
        }
    }

    private func validationLabel(_ status: RecoveredFile.ValidationStatus) -> String {
        switch status {
        case .notChecked: "Not checked"
        case .readable: "Readable"
        case .possiblyPartial: "Possibly partial"
        }
    }
}
