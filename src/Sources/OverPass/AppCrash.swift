import SwiftUI
import AppKit

// OverPass's own crashes. macOS writes a crash report to ~/Library/Logs/DiagnosticReports when OverPass quits
// unexpectedly; at the next start OverPass finds the newest one it hasn't offered yet and offers to send it
// through the report relay, like a crash Wine caught.
enum AppCrash {
    private static let seenKey = "lastCrashReportSeen"
    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// The newest OverPass crash report not offered before (at most a week old), marked as offered.
    static func unseen() -> URL? {
        let seen = UserDefaults.standard.object(forKey: seenKey) as? Date ?? .now.addingTimeInterval(-7 * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard let newest = files
            .filter({ $0.lastPathComponent.hasPrefix("OverPass-") && $0.pathExtension == "ips" })
            .map({ ($0, LogCollector.modified($0)) })
            .filter({ $0.1 > seen })
            .max(by: { $0.1 < $1.1 }) else { return nil }
        UserDefaults.standard.set(newest.1, forKey: seenKey)
        return newest.0
    }

    /// What a crash report says, in short: the version that crashed, the exception, and the crashed thread's frames.
    struct Summary {
        let date: Date
        let version: String
        let exception: String
        let frames: [String]

        /// The exception and the first frames, for the report window and the issue.
        var text: String { ([exception] + frames.prefix(25)).joined(separator: "\n") }
        /// One line for the report block: the exception and the first frame outside Swift's assertion helpers.
        var line: String {
            let frame = frames.first { !$0.contains("_assertionFailure") && !$0.contains("fatalError") } ?? frames.first ?? ""
            return "\(exception) at \(frame)"
        }
    }

    /// Reads a crash report: a line of JSON about the app, then the report itself as JSON.
    static func summary(of url: URL) -> Summary? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let split = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(text[split...].utf8)) as? [String: Any]
        else { return nil }
        let exception = body["exception"] as? [String: Any]
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? 0
        let frames = (faulting < threads.count ? threads[faulting]["frames"] as? [[String: Any]] : nil) ?? []
        return Summary(
            date: LogCollector.modified(url),
            version: header["app_version"] as? String ?? "?",
            exception: [exception?["type"] as? String, exception?["signal"] as? String].compactMap { $0 }.joined(separator: " "),
            frames: frames.map { frame in
                let index = frame["imageIndex"] as? Int ?? -1
                let image = index >= 0 && index < images.count ? images[index]["name"] as? String ?? "?" : "?"
                let symbol = frame["symbol"] as? String ?? String(format: "0x%llx", frame["imageOffset"] as? UInt64 ?? 0)
                return "\(image)  \(symbol)"
            })
    }

    /// The crash report with personal details taken out, zipped for the relay.
    static func zip(_ url: URL) async -> URL? {
        await Task.detached {
            let fm = FileManager.default
            let temp = fm.temporaryDirectory.appendingPathComponent("OverPass Reports/OverPass Crash – \(LogCollector.dateStamp())")
            try? fm.removeItem(at: temp)
            try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  (try? LogCollector.scrub(text).write(to: temp.appendingPathComponent("crash.ips"), atomically: true, encoding: .utf8)) != nil
            else { return nil }
            let zip = temp.appendingPathExtension("zip")
            try? fm.removeItem(at: zip)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", temp.path, zip.path]
            if (try? ditto.run()) != nil { ditto.waitUntilExit() }
            try? fm.removeItem(at: temp)
            return fm.fileExists(atPath: zip.path) ? zip : nil
        }.value
    }
}

/// The report window for OverPass's own crash: what the person was doing, and the crash report.
struct AppCrashView: View {
    let report: URL
    let summary: AppCrash.Summary
    let close: () -> Void
    @State private var description = ""
    @State private var includeReport = true
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OverPass Quit Unexpectedly").font(.title3.bold())
                    Text("It closed \(summary.date.formatted(.relative(presentation: .named))). Sending the crash report helps get it fixed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ReportStep(number: 1, title: "What were you doing?", isLast: false) {
                    TextEditor(text: $description)
                        .font(.body)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        .overlay(alignment: .topLeading) {
                            if description.isEmpty {
                                Text("For example: changed the sort order in the GOG library's list.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                ReportStep(number: 2, title: "Attachments", isLast: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView {
                            Text(summary.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 84)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        Toggle("Include the crash report", isOn: $includeReport)
                    }
                }
            }
            Label("No personal information is included: your name, home folder, computer name and e-mail addresses are "
                  + "taken out of everything that's sent.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small); Text("Sending…").foregroundStyle(.secondary) }
                Spacer()
                Button("Don't Send", action: close).keyboardShortcut(.cancelAction)
                Button("Send Report", action: send).keyboardShortcut(.defaultAction).disabled(sending)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 540)
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let zip = includeReport ? await AppCrash.zip(report) : nil
                let block = LogCollector.reportBlock([
                    "app": "OverPass",
                    "overpass": summary.version,
                    "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(LogCollector.sysctl("kern.osversion") ?? "?"))",
                    "crash": summary.line,
                    "log": zip == nil ? "none" : "crash report",
                ])
                let what = description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "OverPass quit unexpectedly."
                let title = "OverPass crashed: " + String((what.split(whereSeparator: \.isNewline).first.map(String.init) ?? what).prefix(80))
                let body = what + "\n\n```\n" + LogCollector.scrub(summary.text) + "\n```"
                if ReportRelay.url != nil {
                    let issue = try await ReportRelay.send(title: title, what: body, block: block, zip: zip, screenshot: nil)
                    if let zip { try? FileManager.default.removeItem(at: zip) }
                    NSWorkspace.shared.open(issue)
                } else {
                    if let zip {
                        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(zip.lastPathComponent)")
                        try? FileManager.default.moveItem(at: zip, to: desktop)
                        NSWorkspace.shared.activateFileViewerSelecting([desktop])
                    }
                    if let url = LogCollector.issueURL(title: title, what: body, block: block) { NSWorkspace.shared.open(url) }
                }
                close()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
