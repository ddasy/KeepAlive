import Foundation

// Stable preference identifiers; presentation visibility never changes feature state.
enum MenuControl: String, CaseIterable, Identifiable {
    case claude, codex, cross, login, query, sort, countdown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude 保活"
        case .codex: return "Codex 保活"
        case .cross: return "交叉保活"
        case .login: return "开机自启"
        case .query: return "自动查询"
        case .sort: return "自动排序"
        case .countdown: return "隐藏倒计时"
        }
    }
}
