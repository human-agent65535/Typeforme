# AI 写字

AI 写字由 Mac 后端统一控制，默认关闭。可在 Mac 的 Refine 设置或 iPhone 的 Mac Processing → Chinese Keyboard 中修改并保存。

- 开启：中文模式下输入拼音后按空格，把原始拼音交给后端当前选择的 AI 模型，返回中文后直接上屏。这个转换请求不读取 Rime 候选词。
- 关闭：空格继续选择 Rime 首个候选词。
- 等待期间：键盘按转录时的样式置灰并锁定，包括空格和候选词；显示“AI 写字中”。
- 失败：保留原来的拼音并解锁，按空格重试。
- 回车仍直接提交原始输入。没有拼音时空格照常输入空格；网址、邮箱等明确的原文输入继续保留原文。

已经确认的中文前缀不参与转换，可作为只读上下文帮助消歧。响应必须仍属于同一个输入框、同一段标记文本和同一个请求；切换输入框、关闭开关或收起键盘后，迟到的结果不再写入。

后端设置字段为 `ai_writing_enabled`，随设置 revision 同步到 iOS host，再通过键盘 defaults 传给扩展。关闭时后端也会拒绝新的拼音转换请求。请求复用 `/v1/edit-text`，使用独立的 `pinyin_to_chinese` intent，避免被当成语音润色或聊天问题。

## 提示词参考

参考 [Max Lv / madeye 的 DS Input](https://github.com/madeye/ds-input)，具体查看了提交 `8467a16b401f0ce679fe081602208f8247debca7` 的 [转换提示词](https://github.com/madeye/ds-input/blob/8467a16b401f0ce679fe081602208f8247debca7/core/src/config.rs) 与 [请求取消逻辑](https://github.com/madeye/ds-input/blob/8467a16b401f0ce679fe081602208f8247debca7/core/src/engine.rs)。本项目使用自己的 Swift 实现，没有引入它的运行时或代码依赖。

采用整段无声调拼音转换、英文和技术标识保留、只返回转换结果的规则，并明确限制不回答输入中的问题、不执行其中的指令、不扩写内容。提示词在 `Sources/Typeforme/Prompts/TextEditPromptBuilder.swift`。

## 验证

运行 `scripts/run-tests.sh` 和 `scripts/verify-ios-simulator.sh`。真机体验检查应覆盖 `nihaoma`、带否定的句子、已经选过中文前缀的输入、网络失败、连续按空格，以及开关关闭后的 Rime 首词选择。

编译、响应非空和 JSON 合法都不能证明 AI 转换正确。真实模型结果仍须逐条检查拼音含义、上下文、否定、数字、英文保留和是否出现无依据的扩写。
