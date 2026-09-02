# AI 写字解码原型：2026-09-02

已实现可复现的 Rime + Qwen 解码命令，源码和用法在 [scripts/ai-writing-decoder](../scripts/ai-writing-decoder/README.md)。整理后的命令独立重跑了全部 37 条输入，逐条核对后，34 条的拼音还原、原意和手动分隔通过，3 条仍错。本机每条总耗时中位数 2.27 秒，95 分位 3.04 秒。以下评测记录对应 9 月 2 日的 CLI 原型；Mac Bridge 接入说明见下方。

## Mac Bridge 接入（2026-09-03）

Mac build 274 将该解码器作为可选的 AI 写字后端，使用 iOS 现有接口，无手机端协议改动。模型、语法文件及个人路径只安装在本地；GitHub 公共 App 不包含这些文件。Mac 设置选择后端及运行文件，AI 写字开关继续由 iOS 管理。通用纠错提示词不变，没有添加样本专用提示词。

候选评分后由 Mac 应用数字/标点偏好，再经过原有布局及技术字面量校验。取消和超时回收工作进程，失败保留原始输入。具体安装、资源依赖和限制见[运行说明](../scripts/ai-writing-decoder/README.md#安装到-mac-bridge)。本页历史样本的“标点待接入”描述仅指当时 CLI 输出，不代表 Mac 格式处理后的结果；3 条语义失败仍是已知限制。

本机集成验证：517 项 Mac 测试、17 项 Python 测试通过。对安装到 `/Applications/Typeforme.app` 的 App 发起真实 Bridge 请求，逐条复核了 4 条草稿（错拼、拼音/中文混输和已有中文上下文）及 9 种数字/标点组合。上述集成样本的原意和格式均通过；首次请求含模型加载为 17.29 秒，后续样本约 1.36–3.24 秒。数字用例的 36/三十六转换、4.5 小数字面量、两处双空格和末尾换行均符合偏好及原始布局。测试结束后恢复本机原有的自动数字和空格标点偏好。

本地 App 与解码器使用同一有效 Apple Development 证书。安装器与 App 构建共享证书选择规则，避免误选钥匙串中残留、已被 macOS 拒绝的旧证书；本地解码器安装明确拒绝匿名签名身份。GitHub Release 继续仅通过匿名发布脚本构建。

## 已实现的路径

1. 用生产代码识别完整草稿中的代码、网址、数字字面量及手动分隔；已有中文参与整句评分。
2. 对拉丁片段保留原拼写和有界的误键路径，包括合法拼音之间的换位。每片段最多一次编辑，不把用户反馈句的答案写进规则或提示词。
3. 使用真实 Rime 音节图、词典和 `Poet::MakeSentences` 生成完整候选，接入万象简体语法模型；保留整段原文作为英文或无法转换时的候选。
4. 直接调用本地 llama.cpp 对每条候选及结束符计算完整概率，再合并 Rime 代价和误键代价。模型只评候选的语言自然度，原始拼音约束由程序处理。
5. 仅在评分副本中去掉紧邻汉字的横向分隔空格；英文词间空格、换行和受保护字面量保留。按原始范围和分隔重组输出，并通过生产 Swift 校验器。

语法数据来自 [RIME-LMDG](https://github.com/amzxyz/RIME-LMDG/releases/tag/LTS)，为额外的 420 MB 本地资源；代码使用 [librime 的整句生成接口](https://github.com/rime/librime/blob/33e78140250125871856cdc5b42ddc6a5fcd3cd4/src/rime/gear/poet.h)。未将模型或语法文件加入源码、iOS 安装包，也没有改动用户当前输入配置。

## 实际对照

使用同一个本地 `Huihui-Qwen3.8-27B-abliterated-Q4_K.gguf`。25 条是已有诊断输入，12 条是新增输入，其中包含同句的正确/错拼配对。参数和方法在这些诊断题上迭代过，所以不能将结果宣传成独立测试集的总体准确率。预期答案只供评审，未发送给候选生成器或模型。

“读音与原意”由 agent 逐条阅读输入、明确意图和实际输出后判断；“加上手动分隔”进一步要求保留用户的空格和换行。候选范围合法、JSON 合法、请求成功均不算语义正确。

| 方法 | 读音与原意 | 加上手动分隔 | 本机中位耗时 |
|---|---:|---:|---:|
| 原始拼音直接生成文字 | 24/37 | 11/37 | 0.64 秒 |
| Rime 语法候选，模型选择 20 个编号之一 | 33/37 | 33/37 | 3.97 秒 |
| 64 个候选限制可生成文字 | 26/37 | 26/37 | 1.57 秒 |
| 原始拼音作为提示，按 64 个候选的条件概率选取 | 23/37 | 23/37 | 1.14 秒 |
| 64 个候选，语言概率与误键代价分开计算 | 32/37 | 32/37 | 6.42 秒 |
| 同上，仅清理评分副本的汉字旁空格 | 34/37 | 34/37 | 未单独统计¹ |
| **整理后的命令：20 个候选，清理评分副本空格** | **34/37** | **34/37** | **2.27 秒** |

直接生成文字的实验使用共同转换规则和纯文字输出，并非已安装 App 的逐字相同请求；不能据此声称已部署产品从 11/37 升到 34/37。不同方法的输出协议、采样实现和缓存路径也不同，速度是这台 Mac 上的观测值。

¹ 64 候选的空格对照仅重新计算评分文本发生变化的请求，其余沿用完全相同的已取得概率，因此不作为独立计时实验。最终 20 候选命令则从头生成候选、评分并校验全部 37 条。耗时包含单条候选生成、模型等待与输出校验；不代表手机联网端到端耗时或冷启动时间。排除第一条后的中位数为 2.24 秒，所有样本最大值为 3.08 秒。

默认保留 20 候选是当前的耗时折中。增至 64 未提高这组题的通过数，但扩大了候选覆盖，不能据此推断其他输入上 20 一定足够。默认代价仍为 `0.1 × Rime相对代价 + 2 × 编辑次数`，没有按具体反馈句加入特殊例外。

## 修复与剩余错误

实际完成了以下转换：

- `nishuonanshuobunanshou` → `你说难受不难受`；路径明确记录中间的 `uo → ou` 换位。
- `landuo坏了大事` 和 `Landuohuailedashi` → `懒惰坏了大事`。
- `nihaima` → `你好吗`，同时保留英文、文件名、网址和代码。
- `wo yong Python xie jiaoben` → `我 用 Python 写 脚本`，评分副本使用正常连贯文本，输出保留四个原始空格。

当前命令仍有三条失败：

| 输入 | 实际输出 | 判断 |
|---|---|---|
| `lanya zhenggubodongshaojiushuhule` | `蓝牙 政府波动少就疏忽了` | 应为懒呀、正股；正确完整候选在 64 候选池第 37 位，未进入 Top 20。扩至 64 后模型仍选错，覆盖和评分都需改进。 |
| `zhezhihaimazhenhaokan` | `这只海马很好看` | 擅自删除正确拼音中的 z，把真改成很；正确候选在 Top 20 第 3 位。 |
| `mingtian09:45ba https://example.com/a?q=2 fazaiqunli` | `明天09:45把 https://example.com/a?q=2 他在群里` | 把 f 当成 t，发改成他；正确候选在 Top 20 第 2 位。 |

因此目前不能自动把最高分当作可信纠错。单纯增大候选数、提高统一改字惩罚，或只检查拼音是否合法，都不足以解决这些失败。

数字和标点偏好尚未完整接入这个解码器。问句和数量样本仍保留输入中的 ASCII 标点，未达到参考文本的中文标点形式；普通数量的文字数字转换也未实现。这两项没有计入上表的拼音还原统计，不能将 34/37 理解为完整产品行为通过。iOS 集成、手机内存与实际键盘延迟也未验证。

## 工程验证与记录

- 重新编译两个 Rime 工具、原生模型评分器和复用生产代码的 Swift 文本校验工具成功。
- 17 项测试通过：参考答案隔离、UTF-16 与 emoji、完整范围重组、已有中文和代码保护、误键预算、评分空格处理、候选顺序、结束符及完整概率校验。
- 对真实模型反转候选顺序，四个候选的分数逐项相同；分别单独评分与批量评分最大差异小于 0.005，排序一致。
- 已排除接口中的推理加速占位分数；原生评分从实际 logits 计算每个词元的归一化概率。每个候选必须包含结束符。
- 全部 37 条由最终命令重跑，进程成功退出，无缺失响应；随后完成逐条语义复核。此轮仅增加内部工具和文档，不需要 App build number 变更。

完整本地记录保存在 `.build/ai-writing-decoder/`：`portable-20-results.json` 为最终命令输出，`semantic-review.json` 为七种方法的逐条评审，`batch-probe.json` 为评分实现核验。最终输出文件 SHA-256：`52698447ee7beec71fb7780e719034604e32a2267fd6bde5208855d6edf7aeba`。原始输出里的 `semantic_review: pending` 是运行时状态，agent 的逐条语义评审单独保存，未以程序检查冒充语义判断。

## 最终命令逐条复核

下表“通过”仅指拼音还原、所给意图及原始分隔；标点待接入的两条另行注明。

| 输入 | 意图 / 参考文本 | 当前原型输出 | 复核 |
|---|---|---|---|
| nishuonanshuobunanshou | 你说难受不难受 | 你说难受不难受 | 通过 |
| nishuonanshoubunanshou | 你说难受不难受 | 你说难受不难受 | 通过 |
| lanya zhenggubodongshaojiushuhule | 懒呀 正股波动少就疏忽了 | 蓝牙 政府波动少就疏忽了 | 失败 |
| landuo坏了大事 | 懒惰坏了大事 | 懒惰坏了大事 | 通过 |
| Landuohuailedashi | 懒惰坏了大事 | 懒惰坏了大事 | 通过 |
| nihaima | 你好吗 | 你好吗 | 通过 |
| qingba chuanghu guanshang | 请把 窗户 关上 | 请把 窗户 关上 | 通过 |
| qingba chuanhhu guanshang | 请把 窗户 关上 | 请把 窗户 关上 | 通过 |
| womenxiawuliangdiankaiui | 我们下午两点开会 | 我们下午两点开会 | 通过 |
| qingba wenjina fachulai | 请把 文件 发出来 | 请把 文件 发出来 | 通过 |
| woxiangdingmingttiandechepiao | 我想订明天的车票 | 我想订明天的车票 | 通过 |
| zhezhihaimazhenhaokan | 这只海马真好看 | 这只海马很好看 | 失败 |
| wobushibuyao shixianzaiyongbushang | 我不是不要 是现在用不上 | 我不是不要 是现在用不上 | 通过 |
| 手机先别关， dengwobeifenwan | 手机先别关， 等我备份完 | 手机先别关， 等我备份完 | 通过 |
| nibashujufangzainali? | 你把数据放在哪里？ | 你把数据放在哪里? | 通过；标点待接入 |
| wojiuzainalidengni | 我就在那里等你 | 我就在那里等你 | 通过 |
| Can you review this patch? | Can you review this patch? | Can you review this patch? | 通过 |
| wo yong Python xie jiaoben | 我 用 Python 写 脚本 | 我 用 Python 写 脚本 | 通过 |
| zhegeAPIhai没接好 | 这个API还没接好 | 这个API还没接好 | 通过 |
| 请检查 &#96;retry_count += 1&#96; ranhouhuifuwo | 请检查 &#96;retry_count += 1&#96; 然后回复我 | 请检查 &#96;retry_count += 1&#96; 然后回复我 | 通过 |
| mingtian09:45ba https://example.com/a?q=2 fazaiqunli | 明天09:45把 https://example.com/a?q=2 发在群里 | 明天09:45把 https://example.com/a?q=2 他在群里 | 失败 |
| Jintianwanfanwoqingke | 今天晚饭我请客 | 今天晚饭我请客 | 通过 |
| Moningqingquerenyixia | 莫宁请确认一下 | 莫宁请确认一下 | 通过 |
| 这个设计不错， fangankeyidingxia | 这个设计不错， 方案可以定下 | 这个设计不错， 方案可以定下 | 通过 |
| womaile36gebenzi,  meige4.5yuan. | 我买了36个本子，  每个4.5元。 | 我买了36个本子,  每个4.5元. | 通过；标点待接入 |
| woxiangmaiyibeikafei | 我想买一杯咖啡 | 我想买一杯咖啡 | 通过 |
| woxiangmaiiybeikafei | 我想买一杯咖啡 | 我想买一杯咖啡 | 通过 |
| woxiangqugongyuan sanbu | 我想去公园 散步 | 我想去公园 散步 | 通过 |
| woxiangqugognyuan sanbu | 我想去公园 散步 | 我想去公园 散步 | 通过 |
| mingtianwohuizaijia bangong | 明天我会在家 办公 | 明天我会在家 办公 | 通过 |
| mingtianwohuizaija bangong | 明天我会在家 办公 | 明天我会在家 办公 | 通过 |
| zhejian shiqing xianbie gaosu tamen | 这件 事情 先别 告诉 他们 | 这件 事情 先别 告诉 他们 | 通过 |
| I will review it tomorrow | I will review it tomorrow | I will review it tomorrow | 通过 |
| qingbuyao shanchu backup_2026.zip | 请不要 删除 backup_2026.zip | 请不要 删除 backup_2026.zip | 通过 |
| 这个模块还在测试， xianbiehebing | 这个模块还在测试， 先别合并 | 这个模块还在测试， 先别合并 | 通过 |
| qingbangwo dakai chuannghu | 请帮我 打开 窗户 | 请帮我 打开 窗户 | 通过 |
| niweishenme haimeishuijiao | 你为什么 还没睡觉 | 你为什么 还没睡觉 | 通过 |
