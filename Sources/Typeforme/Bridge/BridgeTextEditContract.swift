enum TextEditIntent: String, Codable, Sendable {
    case repairSelection = "repair_selection"
    case command = "command"
}

enum TextEditAction: String, Codable, Sendable {
    case replaceTarget = "replace_target"
}
