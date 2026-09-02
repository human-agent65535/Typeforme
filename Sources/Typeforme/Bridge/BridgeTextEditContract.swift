enum TextEditIntent: String, Codable, Sendable {
    case repairSelection = "repair_selection"
    case command = "command"
    case pinyinToChinese = "pinyin_to_chinese"
}

enum TextEditAction: String, Codable, Sendable {
    case replaceTarget = "replace_target"
}
