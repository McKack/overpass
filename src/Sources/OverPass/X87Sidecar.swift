import Foundation

/// Whether x87sidecar can be used on this Mac. It patches Rosetta's runtime in memory, so it is only trusted after
/// `--probe` passes, checked again for each macOS build and each copy of the tool. Only `--probe` is ever run from
/// here: without `--cooperative` the tool asks macOS for developer-tools authorization.
enum X87Sidecar {
    private static let passedKey = "x87sidecarProbePassed"

    /// Identifies what the last probe saw: this macOS build and this file.
    nonisolated private static var fingerprint: String? {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var build = [CChar](repeating: 0, count: size)
        guard size > 0, sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0,
              let date = (try? FileManager.default.attributesOfItem(atPath: ComponentManager.x87sidecarPath.path))?[.modificationDate] as? Date
        else { return nil }
        return "\(String(cString: build)) \(date.timeIntervalSince1970)"
    }

    /// The tool is here and passed its probe on this macOS build.
    nonisolated static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: ComponentManager.x87sidecarPath.path)
            && fingerprint != nil && UserDefaults.standard.string(forKey: passedKey) == fingerprint
    }

    /// Runs the probe when this macOS build or this copy of the tool hasn't been checked yet.
    nonisolated static func probe() async {
        guard !isReady, FileManager.default.isExecutableFile(atPath: ComponentManager.x87sidecarPath.path),
              let fingerprint else { return }
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = ComponentManager.x87sidecarPath
            process.arguments = ["--probe"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last
            if process.terminationStatus == 0, last == "supported" {
                UserDefaults.standard.set(fingerprint, forKey: passedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: passedKey)
            }
        }.value
    }
}
