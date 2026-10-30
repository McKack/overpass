import Foundation

/// Sends a report through OverPass's report relay (services/report-relay), which files the GitHub issue, so no
/// GitHub account is needed. The report window (ReportCenter.swift) uses it when the relay is set up.
enum ReportRelay {
    /// The relay's address; the `reportRelayURL` setting points elsewhere (a test copy).
    static var url: URL? {
        (UserDefaults.standard.string(forKey: "reportRelayURL") ?? defaultURL).flatMap(URL.init(string:))
    }
    /// Arctim's report relay; OverPass has its own path there.
    private static let defaultURL: String? = "https://reports.arctim.no/overpass"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends the report and returns the issue's address. Without a zip the details block says "log: none". `profile` is
    /// the text of a submitted profile (ProfileSubmit.swift).
    static func send(title: String, what: String, block: String, zip: URL?, screenshot: Data?,
                     profile: String? = nil) async throws -> URL {
        guard let base = url else { throw Failure(message: "The report relay isn't set up in this build.") }
        let boundary = "overpass-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        func file(_ name: String, _ fileName: String, _ type: String, _ data: Data) {
            body.append(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n"
                         + "Content-Type: \(type)\r\n\r\n").data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        field("title", title)
        field("what", what)
        field("steps", "")
        field("block", block)
        if let profile { field("profile", profile) }
        if let zip { file("zip", zip.lastPathComponent.replacingOccurrences(of: "\"", with: ""), "application/zip", try Data(contentsOf: zip)) }
        if let screenshot { file("screenshot", "screenshot.jpg", "image/jpeg", screenshot) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: base.appendingPathComponent("report"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let link = json?["url"] as? String, let issue = URL(string: link) { return issue }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw Failure(message: json?["error"] as? String ?? "The relay answered with status \(status).")
    }
}
