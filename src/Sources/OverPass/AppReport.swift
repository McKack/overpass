import SwiftUI
import AppKit

// The Help menu's report on OverPass itself and feature request: not tied to a title, so no log, only what the person
// writes, a screenshot if they want and the versions involved. They go out like any report (ReportCenter.swift); the
// details block's `kind` tells the report check and the relay what they are.

enum AppReportKind {
    case issue, feature
}

struct AppReportView: View {
    let kind: AppReportKind
    let overGame: Bool
    let close: () -> Void
    @State private var description = ""
    @State private var screenshot: NSImage?
    @State private var sending = false
    @State private var error: String?

    init(kind: AppReportKind, screenshot: NSImage?, overGame: Bool, close: @escaping () -> Void) {
        self.kind = kind
        self.overGame = overGame
        self.close = close
        _screenshot = State(initialValue: screenshot)
    }

    private var isIssue: Bool { kind == .issue }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isIssue ? "Report an Issue with OverPass" : "Request a Feature").font(.title3.bold())
                    Text(isIssue ? "For a problem with one game, use Report Issue… on that game: it sends the game's log too."
                         : "Tell us what you'd like OverPass to do.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ReportStep(number: 1, title: isIssue ? "What happened?" : "What would you like?", isLast: false) {
                    ReportTextEditor(text: $description, placeholder: isIssue
                                     ? "Explain the issue you encountered. Are you able to make it happen again, and if so, how?"
                                     : "Describe the feature, and what you'd use it for.")
                }
                ReportStep(number: 2, title: "Attachments", isLast: true) {
                    HStack(spacing: 10) {
                        if let screenshot {
                            Image(nsImage: screenshot).resizable().scaledToFit()
                                .frame(height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                            Button("Remove") { self.screenshot = nil }
                        } else {
                            Button("Attach Screenshot…") { screenshot = ReportView.chooseScreenshot() ?? screenshot }
                        }
                    }
                    Text(isIssue ? "Your OverPass, Wine and Runtime versions and your Mac's model and macOS version go with the report."
                         : "Your OverPass and macOS versions go with the request.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ReportPrivacyNote()
            if isIssue && !overGame { ReportHotKeyHint() }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small); Text("Sending…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(isIssue ? "Send Report" : "Send Request", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 540)
    }

    private var block: String {
        isIssue ? LogCollector.reportBlock([
            "app": "OverPass",
            "kind": "general",
            "overpass": LogCollector.overpassFact,
            "wine": LogCollector.wineFact,
            "runtime": LogCollector.runtimeFact,
            "macos": LogCollector.macOSFact,
            "mac": LogCollector.macFact,
            "log": "none",
        ]) : LogCollector.reportBlock([
            "app": "OverPass",
            "kind": "feature",
            "overpass": LogCollector.overpassFact,
            "macos": LogCollector.macOSFact,
            "log": "none",
        ])
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                let what = LogCollector.scrub(description.trimmingCharacters(in: .whitespacesAndNewlines))
                let firstLine = what.split(whereSeparator: \.isNewline).first.map(String.init) ?? what
                let title = (isIssue ? "OverPass: " : "Feature request: ") + String(firstLine.prefix(80))
                let jpeg = screenshot.flatMap(ReportView.jpeg)
                if ReportRelay.url != nil {
                    NSWorkspace.shared.open(try await ReportRelay.send(title: title, what: what, block: block, zip: nil, screenshot: jpeg))
                } else {
                    if let jpeg {
                        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/OverPass Screenshot.jpg")
                        try? jpeg.write(to: file)
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    if let url = LogCollector.issueURL(title: title, what: what, block: block, form: isIssue ? "report.yml" : "feature.yml") {
                        NSWorkspace.shared.open(url)
                    }
                }
                close()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
