import Foundation
import Darwin

// MARK: - 外部命令执行
enum Shell {
    static func run(_ launch: String, _ args: [String], env: [String: String]) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("launch error: \(error)", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    // 私有 API responsibility_spawnattrs_setdisclaim：让 spawn 出来的子进程“自负 TCC/钥匙串责任”，
    // 不再把访问算到本 App（ad-hoc 临时签名、macOS 认不出稳定身份 → 只给“允许”不给“始终允许”，每次都弹）头上。
    // 用 dlsym 运行时取符号：取不到就退化成普通 spawn（功能不受影响，只是可能仍弹框）。
    private typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let setDisclaim: DisclaimFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(sym, to: DisclaimFn.self)
    }()

    // 与 run 等价，但子进程“脱钩”——钥匙串/TCC 责任落到稳定的系统身份而非本 App。
    // 用于保活的 claude -p：避免因本 App 是 ad-hoc 签名而每次弹“允许访问钥匙串”框。
    static func runDisclaimed(_ launch: String, _ args: [String], env: [String: String]) -> (out: String, code: Int32) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        _ = setDisclaim?(&attr, 1)                       // 关键：子进程自负钥匙串责任（取不到符号则跳过）

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }

        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else { return ("pipe() failed", -1) }
        let readFD = fds[0], writeFD = fds[1]
        posix_spawn_file_actions_adddup2(&fa, writeFD, 1)  // 子进程 stdout → 管道
        posix_spawn_file_actions_adddup2(&fa, writeFD, 2)  // 子进程 stderr → 管道
        posix_spawn_file_actions_addclose(&fa, readFD)
        posix_spawn_file_actions_addclose(&fa, writeFD)

        var cArgs: [UnsafeMutablePointer<CChar>?] = ([launch] + args).map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { for p in cArgs where p != nil { free(p) }; for p in cEnv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, launch, &fa, &attr, cArgs, cEnv)
        close(writeFD)                                   // 父进程关写端 → 子进程退出后读到 EOF
        if rc != 0 { close(readFD); return ("posix_spawn failed (rc=\(rc))", -1) }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &buf, buf.count)
            if n > 0 { out.append(buf, count: n) } else { break }   // 0=EOF, <0=错误 → 结束
        }
        close(readFD)

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1   // WIFEXITED ? WEXITSTATUS : 异常
        return (String(data: out, encoding: .utf8) ?? "", code)
    }
}
