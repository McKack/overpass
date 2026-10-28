import SwiftUI
import UniformTypeIdentifiers

struct InstallSheet: View {
    @Environment(BottleManager.self) private var manager
    @Environment(ProfileStore.self) private var profiles
    @Environment(ComponentManager.self) private var components
    @Environment(\.dismiss) private var dismiss

    let initialProfile: GameProfile?
    var initialFile: URL? = nil
    @State private var installer = GameInstaller()
    @State private var profile: GameProfile?
    @State private var installerFile: URL?
    @State private var search = ""
    @State private var location = ContainerLocations.favorite
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch installer.phase {
            case .idle:
                chooser
            case .needsComponent(let id):
                ComponentPrompt(component: id, onContinue: { override in
                    start(graphicsOverride: override)
                }, onCancel: { installer.reset() })
            case .running, .finished:
                progress
            }
        }
        .frame(width: 560, height: 480)
        .onAppear {
            if let initialProfile, profile == nil { profile = initialProfile }
            if let initialFile, installerFile == nil { use(initialFile) }
        }
    }

    // MARK: Choose what to install

    private var filtered: [GameProfile] {
        let ready = profiles.profiles.filter { !$0.comingSoon }
        return search.isEmpty ? ready : ready.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install").font(.title2.bold())

            HStack {
                Button("Choose Installer File…", action: chooseFile)
                if let installerFile {
                    Label(installerFile.lastPathComponent, systemImage: "doc")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Or pick from the catalog").font(.headline).padding(.top, 4)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            ScrollViewReader { proxy in
                List(filtered, selection: $profile) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            if let category = p.category {
                                Text(category).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        RatingLabel(rating: p.rating, compact: true)
                    }
                    .tag(p)
                }
                .frame(minHeight: 180)
                .focused($listFocused)
                .onAppear {
                    // Opened from a launcher on Home: show its row selected and focused, not the search field.
                    // Deferred so it wins over the sheet giving the search field first focus.
                    guard let initialProfile else { return }
                    DispatchQueue.main.async {
                        listFocused = true
                        proxy.scrollTo(initialProfile.id, anchor: .center)
                    }
                }
            }

            if let profile, let notes = profile.notes {
                Text(notes).font(.caption).foregroundStyle(.secondary)
            }
            // No direct download: the installer comes from the developer's page, then Choose Installer File.
            if let profile, installerFile == nil, profile.installer?.canDownload != true, let page = profile.installer?.downloadPage {
                Link("Get the \(profile.name) installer", destination: page).font(.caption)
            }

            // Only for a new container, and only once there's somewhere besides the default to put it.
            if ContainerLocations.all.count > 1, !joinsExistingContainer {
                Picker("Container location", selection: $location) {
                    ForEach(ContainerLocations.all, id: \.self) { url in
                        Text("\(ContainerLocations.displayName(of: url)) (\(ContainerLocations.freeSpaceText(at: url)))").tag(url)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Install") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    /// A launcher's games go into the launcher's container, wherever it is.
    private var joinsExistingContainer: Bool {
        guard let group = profile?.bottle.group else { return false }
        return manager.bottles.contains { $0.group == group }
    }

    private var canStart: Bool {
        installerFile != nil || profile?.installer?.canDownload == true
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe] + ["msi"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a Windows installer (.exe or .msi)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    private func use(_ url: URL) {
        installerFile = url
        // Recognize known installers so their profile applies automatically.
        if let match = profiles.match(installer: url) { profile = match }
    }

    private func start(graphicsOverride: GraphicsBackend? = nil) {
        let id = profile?.id
        Task {
            if let id { manager.busyProfiles.insert(id) }
            await installer.start(profile: profile, installerFile: installerFile, bottles: manager,
                                  components: components, graphicsOverride: graphicsOverride, location: location)
            if let id { manager.busyProfiles.remove(id) }
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.map { "Installing \($0.name)" } ?? "Installing").font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                ForEach(installer.steps) { step in
                    HStack(alignment: .firstTextBaseline) {
                        stepIcon(step.state).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                            if let detail = step.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }

            if installer.steps.contains(where: { $0.id == "install" && $0.state == .running }),
               !installer.runsUnattended, !installer.waitingForChildren {
                HStack {
                    Text("The installer runs in its own window. Follow its steps; OverPass carries on when it closes.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Installer") { manager.showWineWindows() }
                }
            }

            if installer.waitingForChildren {
                HStack {
                    Text("The installer has finished, but programs it started are still running. If the launcher is already open, you can continue.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue") { installer.stopWaitingRequested = true }
                }
            }

            if let error = installer.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            if case .finished(true) = installer.phase {
                if installer.newApps.isEmpty {
                    Text("The installer finished, but it didn't create any shortcuts. You can run programs from the container with Quick Run.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let bottle = installer.bottle {
                    ForEach(installer.newApps) { app in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(app.name)
                            Spacer()
                            OpenButton(opening: manager.isOpening(in: bottle, program: app.executable)) {
                                try? manager.launchApp(app, in: bottle)
                            }
                        }
                    }
                }
            }

            LogDisclosure(text: installer.log)

            Spacer(minLength: 0)
            HStack {
                Spacer()
                if case .finished = installer.phase {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func stepIcon(_ state: GameInstaller.StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Shown when a profile asks for a graphics component that isn't installed yet.
struct ComponentPrompt: View {
    @Environment(ComponentManager.self) private var components
    let component: ComponentID
    let onContinue: (GraphicsBackend?) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(component == .d3dmetal ? "This game requires D3DMetal" : "This game works best with \(component.name)",
                  systemImage: "cpu")
                .font(.title2.bold())

            if component == .d3dmetal {
                Text("D3DMetal is included with Apple's Game Porting Toolkit. Apple doesn't allow other apps to redistribute it, so download the toolkit from Apple (free, Apple Account sign-in required), then import it here.")
            } else {
                Text(component.summary)
            }

            if let blocker = components.blocker(for: component) {
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if let error = components.lastError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                if component == .d3dmetal {
                    Link("Download from Apple", destination: ComponentManager.gptkDownloadPage)
                    Button("Import Game Porting Toolkit…") { install() }
                } else {
                    Button("Install \(component.name)") { install() }
                }
                if components.busy != nil { ProgressView().controlSize(.small) }
            }
            .disabled(components.blocker(for: component) != nil || components.busy != nil)

            Spacer()
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Continue with Default Graphics") { onContinue(.auto) }
            }
        }
        .padding(20)
    }

    private func install() {
        Task {
            await components.install(component)
            if components.isInstalled(component) { onContinue(nil) }
        }
    }
}

/// Rating shown under an app's name: a medal in the tier's colour and its title.
struct RatingLabel: View {
    let rating: GameProfile.Rating
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: rating.tier == .untested ? "medal" : "medal.fill")
                .foregroundStyle(color)
            Text(rating.tier.title)
                .foregroundStyle(rating.tier == .untested ? .secondary : .primary)
        }
        .font(.caption.weight(.medium))
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        var parts = [rating.tier.summary]
        if let testedWith = rating.testedWith { parts.append("Tested with \(testedWith)") }
        if let date = rating.date { parts.append(date) }
        if let notes = rating.notes { parts.append(notes) }
        return parts.joined(separator: "\n")
    }

    private var color: Color {
        switch rating.tier {
        case .platinum: Color(red: 0.62, green: 0.78, blue: 0.86)
        case .gold: Color(red: 0.93, green: 0.73, blue: 0.20)
        case .silver: Color(red: 0.70, green: 0.72, blue: 0.75)
        case .bronze: Color(red: 0.76, green: 0.50, blue: 0.29)
        case .borked: .red
        case .untested: .secondary
        }
    }
}

/// Command output under a collapsed "Details" disclosure, following the newest line.
struct LogDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Details", isExpanded: $isExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 0).id("end")
                }
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(height: 130)
        }
    }
}
