import Foundation

// Waiting for an installer the way CrossOver does. OverPass Wine (CodeWeavers' ntdll) passes the file
// descriptor named by WINE_WAIT_CHILD_PIPE on to every Wine process it starts; Wine's own background
// processes (services, explorer) close it, and so does the program named by WINE_WAIT_CHILD_PIPE_IGNORE.
// When the read end reaches EOF, everything the installer started has exited, not just the installer
// itself. Foundation's Process closes extra descriptors, hence posix_spawn.
extension BottleManager {
    struct InstallerRun {
        /// Exit status of the program that was started.
        var status: Int32
        /// False when the caller stopped waiting before every child exited.
        var allExited: Bool
    }

    /// Runs Wine with `args` and returns once it and everything it started have exited (except `ignore`),
    /// or when `stopWaiting` returns true after the first program has exited.
    func runWaitingForChildren(_ args: [String], in bottle: Bottle, ignore: String?,
                               log: @escaping @MainActor (String) -> Void,
                               mainExited: @escaping @MainActor () -> Void,
                               stopWaiting: @escaping @MainActor () -> Bool) async throws -> InstallerRun {
        let template = try exeProcessTemplate(args, in: bottle)
        var env = template.environment
        var waitFds: [Int32] = [0, 0], logFds: [Int32] = [0, 0]
        guard pipe(&waitFds) == 0, pipe(&logFds) == 0 else { throw POSIXError(.EMFILE) }
        let (waitRead, waitWrite, logRead, logWrite) = (waitFds[0], waitFds[1], logFds[0], logFds[1])
        env["WINE_WAIT_CHILD_PIPE"] = String(waitWrite)
        if let ignore { env["WINE_WAIT_CHILD_PIPE_IGNORE"] = ignore }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logWrite, 1)
        posix_spawn_file_actions_adddup2(&actions, logWrite, 2)
        posix_spawn_file_actions_addinherit_np(&actions, waitWrite)
        posix_spawn_file_actions_addchdir_np(&actions, template.directory.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Everything not named above is closed in the child, so the read ends never leak into Wine.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([template.executable.path] + template.arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, template.executable.path, &actions, &attr, argv, envp)
        close(waitWrite)
        close(logWrite)
        guard rc == 0 else {
            close(waitRead); close(logRead)
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOEXEC)
        }

        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(logRead, &buf, buf.count)
                if n <= 0 { break }
                let text = String(decoding: buf[0..<n], as: UTF8.self)
                Task { @MainActor in log(text) }
            }
            close(logRead)
        }

        let status: Int32 = await withCheckedContinuation { cont in
            Thread.detachNewThread {
                var st: Int32 = 0
                waitpid(pid, &st, 0)
                cont.resume(returning: (st & 0x7f) == 0 ? (st >> 8) & 0xff : -1)
            }
        }
        mainExited()

        // Poll so the wait can be abandoned; a blocked read() can't be interrupted from another thread.
        var allExited = false
        while true {
            let ready = await Task.detached {
                var pfd = pollfd(fd: waitRead, events: Int16(POLLIN), revents: 0)
                return poll(&pfd, 1, 500)
            }.value
            if ready > 0 {
                var byte: UInt8 = 0
                if read(waitRead, &byte, 1) <= 0 { allExited = true; break }
            }
            if stopWaiting() || Task.isCancelled { break }
        }
        close(waitRead)
        return InstallerRun(status: status, allExited: allExited)
    }
}
