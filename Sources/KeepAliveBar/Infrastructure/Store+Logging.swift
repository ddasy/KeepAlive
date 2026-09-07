import Foundation

extension Store {
    // 日志用小工具：时刻 / 百分比 / 可选 Bool 的紧凑字符串
    func fmt(_ d: Date?) -> String {
        guard let d = d else { return "nil" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: d)
    }
    func pctStr(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }
    func boolStr(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "nil" }

    func log(_ s: String) {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(s)\n"
        let path = "\(supportDir)/keepalive.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); if let d = line.data(using: .utf8) { h.write(d) }; try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
