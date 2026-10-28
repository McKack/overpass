import SwiftUI
import Foundation

// MARK: - Setup Manager

@MainActor
@Observable
class SetupManager {
    enum Step: Int, CaseIterable {
        case welcome
        case checking
        case install
        case permissions
        case done
    }

    enum DependencyStatus {
        case unknown, checking, found, missing
    }

    enum Source {
        case component(ComponentID)  // installed by ComponentManager
        case system(String)          // can't install for the user; shows this command instead
    }

    struct Dependency: Identifiable {
        let id: String
        let name: String
        let description: String
        var status: DependencyStatus = .unknown
        let required: Bool
        let source: Source
        let isPresent: @Sendable () -> Bool
    }

    var currentStep: Step = .welcome
    var dependencies: [Dependency] = [
        Dependency(
            id: "rosetta",
            name: "Rosetta 2",
            description: "Runs the x86_64 Wine build on Apple silicon",
            required: true,
            source: .system("softwareupdate --install-rosetta --agree-to-license"),
            isPresent: { WineInstaller.rosettaAvailable }
        ),
        Dependency(
            id: "wine",
            name: "Wine",
            description: "OverPass Wine, the Windows compatibility layer — downloaded into OverPass (~260 MB)",
            required: true,
            source: .component(.wine),
            isPresent: { BottleManager.findWine() != nil }
        ),
        Dependency(
            id: "addons",
            name: "Wine Mono & Gecko",
            description: "Wine's .NET runtime and HTML engine, so containers don't ask to download them (~190 MB)",
            required: false,
            source: .component(.addons),
            isPresent: { BottleManager.findWine().map { WineAddons.missing(wineRoot: $0).isEmpty } ?? false }
        ),
        Dependency(
            id: "winetricks",
            name: "Winetricks (optional)",
            description: "Installs Windows runtimes games need (downloaded, ~1 MB)",
            required: false,
            source: .component(.winetricks),
            isPresent: { FileManager.default.isExecutableFile(atPath: ComponentManager.winetricksPath.path) }
        ),
    ]

    var isInstalling = false
    var installOutput = ""
    var installFinished = false
    var installError: String?
    var bottlesDirectoryCreated = false

    private var cancelled = false
    private weak var components: ComponentManager?

    var allDependenciesFound: Bool {
        dependencies.allSatisfy { $0.status == .found || !$0.required }
    }

    var missingDependencies: [Dependency] {
        dependencies.filter { $0.status == .missing }
    }

    /// Missing items the wizard can install itself.
    var installableMissing: [Dependency] {
        missingDependencies.filter {
            if case .component = $0.source { return true }
            return false
        }
    }

    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedSetup") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedSetup") }
    }

    // MARK: - Dependency Checks

    func runChecks() async {
        currentStep = .checking

        for i in dependencies.indices {
            dependencies[i].status = .checking
            try? await Task.sleep(for: .milliseconds(300)) // brief pause so user sees progress
            let check = dependencies[i].isPresent
            let found = await Task.detached { check() }.value
            dependencies[i].status = found ? .found : .missing
        }

        let bottlesDir = Bottle.bottlesDirectory()
        do {
            try FileManager.default.createDirectory(at: bottlesDir, withIntermediateDirectories: true)
            bottlesDirectoryCreated = true
        } catch {
            bottlesDirectoryCreated = false
        }

        currentStep = missingDependencies.isEmpty ? .permissions : .install
    }

    private func recheck() async {
        for i in dependencies.indices {
            let check = dependencies[i].isPresent
            dependencies[i].status = await Task.detached { check() }.value ? .found : .missing
        }
    }

    // MARK: - Install

    func installMissing(using components: ComponentManager) async {
        self.components = components
        isInstalling = true
        cancelled = false
        installOutput = ""
        installError = nil
        installFinished = false

        for dep in installableMissing {
            guard !cancelled, case .component(let id) = dep.source else { continue }
            let logStart = components.log.endIndex
            await components.install(id)
            appendOutput(String(components.log[logStart...]) + "\n")
            if let error = components.lastError {
                installError = error
            }
        }

        isInstalling = false
        installFinished = true
        await recheck()
    }

    private func appendOutput(_ text: String) {
        installOutput += text
    }

    func cancelInstall() {
        cancelled = true
        components?.cancel()
    }

    func completeSetup(bottleManager: BottleManager) {
        Self.hasCompletedSetup = true
        bottleManager.detectWine()
    }
}

// MARK: - Setup Wizard View

struct SetupWizardView: View {
    @Environment(BottleManager.self) private var bottleManager
    @State private var setupManager = SetupManager()
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            StepIndicatorBar(current: setupManager.currentStep)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            // Content
            Group {
                switch setupManager.currentStep {
                case .welcome:
                    WelcomeStepView(setupManager: setupManager, onSkip: {
                        setupManager.completeSetup(bottleManager: bottleManager)
                        onComplete()
                    })
                case .checking:
                    CheckingStepView(setupManager: setupManager)
                case .install:
                    InstallStepView(setupManager: setupManager)
                case .permissions:
                    PermissionsStepView(setupManager: setupManager)
                case .done:
                    DoneStepView(setupManager: setupManager, bottleManager: bottleManager, onComplete: onComplete)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - Step Indicator

private struct StepIndicatorBar: View {
    let current: SetupManager.Step

    private let steps: [(SetupManager.Step, String)] = [
        (.welcome, "Welcome"),
        (.checking, "Check"),
        (.install, "Install"),
        (.permissions, "Access"),
        (.done, "Done"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(steps, id: \.0) { step, label in
                HStack(spacing: 4) {
                    Circle()
                        .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .secondary)
                }
                if step != .done {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Welcome Step

private struct WelcomeStepView: View {
    let setupManager: SetupManager
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: BottleIcon.symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Welcome to OverPass")
                .font(.title.bold())

            Text("OverPass needs Wine and a few tools to run Windows applications.\nLet's make sure everything is set up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            Spacer()

            HStack {
                Button("Skip Setup") {
                    onSkip()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Get Started") {
                    Task {
                        await setupManager.runChecks()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .padding()
    }
}

// MARK: - Checking Step

private struct CheckingStepView: View {
    let setupManager: SetupManager

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Checking Dependencies")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                ForEach(setupManager.dependencies) { dep in
                    HStack {
                        Group {
                            switch dep.status {
                            case .unknown:
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            case .checking:
                                ProgressView()
                                    .controlSize(.small)
                            case .found:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .missing:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(width: 20)

                        VStack(alignment: .leading) {
                            Text(dep.name)
                                .font(.body.bold())
                            Text(dep.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Divider()

                HStack {
                    Image(systemName: setupManager.bottlesDirectoryCreated
                        ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(setupManager.bottlesDirectoryCreated ? .green : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading) {
                        Text("Containers Directory")
                            .font(.body.bold())
                        Text("~/Library/Application Support/OverPass/Bottles/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Install Step

private struct InstallStepView: View {
    @Bindable var setupManager: SetupManager
    @Environment(ComponentManager.self) private var components

    var body: some View {
        VStack(spacing: 12) {
            Text("Install Missing Components")
                .font(.title2.bold())
                .padding(.top)

            if !setupManager.isInstalling && !setupManager.installFinished {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(setupManager.missingDependencies) { dep in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(dep.name, systemImage: dep.required ? "xmark.circle" : "minus.circle")
                                .foregroundStyle(dep.required ? .orange : .secondary)
                            Group {
                                switch dep.source {
                                case .component(let id):
                                    Text("Will be downloaded from \(id.credit.url.host() ?? "")\(id.credit.url.path())")
                                case .system(let command):
                                    Text("Run in Terminal (needs an admin password): \(command)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            if components.wineInstaller.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: components.wineInstaller.progress)
                    Text(components.wineInstaller.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            LogDisclosure(text: setupManager.installOutput)
                .padding(.horizontal)

            if let error = setupManager.installError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer(minLength: 0)

            HStack {
                if setupManager.isInstalling {
                    Button("Cancel") {
                        setupManager.cancelInstall()
                    }
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .foregroundStyle(.secondary)
                } else if setupManager.installFinished {
                    if setupManager.allDependenciesFound {
                        Spacer()
                        Button("Continue") {
                            setupManager.currentStep = .permissions
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Retry") {
                            Task { await setupManager.installMissing(using: components) }
                        }
                        Spacer()
                        Text("Some components are still missing.")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Button("Continue Anyway") {
                            setupManager.currentStep = .permissions
                        }
                    }
                } else {
                    Button("Skip") {
                        setupManager.currentStep = .permissions
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Install") {
                        Task {
                            await setupManager.installMissing(using: components)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(setupManager.installableMissing.isEmpty)
                }
            }
            .padding()
        }
    }
}

// MARK: - Permissions Step

private struct PermissionsStepView: View {
    let setupManager: SetupManager
    @State private var permissions = PermissionsManager()

    var body: some View {
        VStack(spacing: 16) {
            Text("Allow Access")
                .font(.title2.bold())
                .padding(.top)
            Text("Windows programs reach your files, drives and microphone through OverPass. macOS asks about each once; answering now keeps the questions out of your installs and games.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(alignment: .leading, spacing: 14) {
                PermissionsList(permissions: permissions)
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 0)

            HStack {
                Button("Skip") { setupManager.currentStep = .done }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(permissions.isAsking)
                Spacer()
                if permissions.allAsked {
                    Button("Continue") { setupManager.currentStep = .done }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Allow All") { Task { await permissions.requestAll() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(permissions.isAsking)
                }
            }
            .padding()
        }
    }
}

// MARK: - Done Step

private struct DoneStepView: View {
    let setupManager: SetupManager
    let bottleManager: BottleManager
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: setupManager.allDependenciesFound
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(setupManager.allDependenciesFound ? .green : .orange)

            Text(setupManager.allDependenciesFound ? "You're All Set" : "Setup Complete")
                .font(.title.bold())

            if setupManager.allDependenciesFound {
                Text("OverPass is ready. Create a container to get started.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    Text("Some dependencies are missing.")
                        .foregroundStyle(.secondary)
                    Text("You can install them later from Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Finish") {
                    setupManager.completeSetup(bottleManager: bottleManager)
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .padding()
    }
}
