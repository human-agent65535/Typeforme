# AI 写字拼音解码器

可直接运行的 Mac 命令行原型：拼音误键候选 → Rime 音节图和整句候选 → 本地 Qwen 整句概率评分 → 按原文范围重组。输入和输出为 JSON Lines。它使用项目现有的 `VerbatimSpanMask`、`PinyinDraftLayout` 和 `TextEditValidator` 检查代码、网址及手动分隔位置。

Mac Bridge 可以将此解码器选为 AI 写字后端；iOS 继续使用现有的 `/v1/edit-text` 接口。AI 写字的启用和触发仍在 iOS 键盘内。Mac 默认保留模型提示词后端，选择拼音解码后才使用本地 Rime + Qwen 路径。模型和语法数据不进入源码或公共 App 安装包。

## 构建

需要完整 Xcode、Python 3.10+、Homebrew 的 librime、glog 和 Boost 头文件，以及已经编译好的 llama.cpp 动态库。使用与动态库版本匹配的 librime 和 llama.cpp 源码。当前验证环境为 librime 1.17.0，源码提交 `33e78140250125871856cdc5b42ddc6a5fcd3cd4`；llama.cpp 为 `b10715-92cedc867`。原生接口会随版本变化，不能用不匹配的旧头文件构建。

```sh
scripts/build-rime-ios-data.sh

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export TYPEFORME_RIME_SOURCE=/absolute/path/to/librime
export TYPEFORME_LLAMA_SOURCE=/absolute/path/to/llama.cpp
bash scripts/ai-writing-decoder/build.sh
```

`TYPEFORME_LLAMA_LIB` 可指定动态库目录，默认是 `$TYPEFORME_LLAMA_SOURCE/build/bin`。`TYPEFORME_BOOST_INCLUDE` 可指定包含 `boost/` 的头文件目录，默认使用 Homebrew。构建产物在 `.build/ai-writing-decoder-tools/`；可通过 `TYPEFORME_DECODER_BUILD` 更改，运行时相应传入 `--tools-directory`。

还需要 librime 的 octagram 插件及 [RIME-LMDG 的简体语法数据](https://github.com/amzxyz/RIME-LMDG/releases/tag/LTS)。本次使用 `wanxiang-lts-zh-hans.gram`，文件大小 420,248,620 字节，SHA-256 为 `1635588006d79cc6955fbcf3d8de12822a36856eb5408735a8b4a2952b16cadf`。该数据不是手机现有 Rime 词典自带的文件。

## 安装到 Mac Bridge

完成构建后：

```sh
export TYPEFORME_DECODER_MODEL=/absolute/path/to/qwen-model.gguf
export TYPEFORME_DECODER_GRAMMAR=/absolute/path/to/wanxiang-lts-zh-hans.gram
export TYPEFORME_LLAMA_LIB=/absolute/path/to/llama.cpp/build/bin
bash scripts/ai-writing-decoder/install.sh
```

安装器把 Python 源码、原生程序、动态库、Rime 表和语法数据复制到 `~/Library/Application Support/Typeforme/ai-writing/` 的独立运行目录，修正动态库引用并使用本机 Apple Development 身份签名。最后原子写入仅本机使用的 `runtime.json`，保留已有运行目录以免中断进行中的请求。`TYPEFORME_DECODER_PYTHON` 可指定 Python 3.10+，`TYPEFORME_DECODER_PLUGIN` 可指定 octagram 插件。GGUF 仍引用明确选择的本机文件，不复制或下载其他模型；不要删除该模型或 Python 安装。

在 Mac 设置 → 写字 → 提示词，将 **AI 写字后端** 选择为 **拼音解码（Rime + Qwen）**。页面显示解码模型，模型提示词后端的 AI 写字提示词在此路径不参与评分。运行文件缺失、模型失败、超时或取消均明确失败，原始草稿保留，不偷偷换后端。切回模型提示词后端会在当前请求结束后释放解码模型。

解码器通过私有标准输入/输出与 App 通信，无新增网络端口。模型在连续请求间复用；冷启动预算 60 秒，后续请求 30 秒。同一解码器一次只处理一段草稿，并发请求返回忙碌错误。取消、App 退出或崩溃会回收整个原生进程组。

Mac 在解码后应用数字和标点偏好：中文明确数量按“数字/文字”转换；代码、网址、日期、时间、小数和版本字面量保持原样；正常标点、英文标点和空格模式使用现有格式规则。手动空格与换行在格式处理后原样重组。无需更新 iOS 协议或将 Rime/模型加入手机包。

## 转换一段输入

```sh
python3 scripts/ai-writing-decoder/decode.py \
  --grammar-file /absolute/path/to/wanxiang-lts-zh-hans.gram \
  --rime-plugin /absolute/path/to/librime-octagram.dylib \
  --model-path /absolute/path/to/model.gguf \
  --backend-directory /absolute/path/to/llama.cpp/build/bin \
  --score-layout prose <<'EOF'
{"input":"你好  nizaima"}
{"input":"nishuonanshuobunanshou"}
EOF
```

一个进程可以连续处理多行，复用已加载的模型和 Rime。首次请求包含模型加载时间。当前评分模板仅适用于 Qwen ChatML；不能假定任意 GGUF 模型都兼容。它会额外加载一个本地模型实例，已运行的模型服务不会被修改或停止。

只查看拼音、误键路径和整句候选时，使用 `--candidates-only`，不必提供模型和后端目录。加 `--diagnostics` 会在本地输出各候选、改动和分数，便于逐条检查。

输入字段：

- `input`：完整草稿；支持现有中文、英文和拼音混合，最多 500 个字符。
- `context_before`：可选的前文；只参与评分，不进入替换文本。
- `vocabulary_candidates`：可选的明确用户词库提示，包含 `surface`、`speech_hint`、`matched_span`，可附 `type`。

不会接收答案或模型要模仿的示例。`semantic_review: "pending"` 表示结构检查通过也不能证明意思正确。CLI 的输出停在格式处理之前，返回的 `output_stage` 明确标识这一点；数字和标点偏好由 Mac 调用层应用。App 服务模式额外使用 `id` 匹配请求响应，该 ID 不进入候选生成器或模型。Mac 仅使用最近 160 个前文字符作为只读评分上下文。后文条件、长段落、简拼和多处连续错键也不在当前已验证范围内。

## 评分和边界

每个拉丁片段保留原拼写，以及有界的漏键、重复键、相邻键和字母换位路径，每片段最多一次编辑；合法拼音之间的换位也会保留。候选必须完整覆盖对应范围，不能把 Rime 的部分词条当成整句。现有中文、代码、网址和连续大写缩写不由候选生成器改写。

候选始终包括保留原文的选项。默认保留 20 条完整候选，可用 `--candidate-count` 调整；完整对照也测试了 64 条。整句评分为：

```text
score = 完整候选及结束符的 log P
        − native_weight × Rime 相对代价
        − edit_penalty × 拼写编辑次数
```

默认 `native_weight=0.1`、`edit_penalty=2` 是实验参数，尚未校准成真实误键概率。模型逐条计算候选的概率，不看错拼草稿、不生成改写，也不通过候选编号选择。直接读取原生 logits，包含结束符；缺少任何候选、词元分数或结束符都会失败。不能将推理加速接口返回的 `0 + empty top_logprobs` 当作真实概率。

`--score-layout raw` 按原始空格评分；默认 `prose` 只在评分副本中去掉紧邻汉字的横向分隔空格。英文词间空格、换行和受保护字面量保留。最终输出仍使用原始候选及其原始分隔位置。两种方式的效果需要分别评测。

原生评分器每组最多 8 条候选，每条含提示词及结束符最多 512 个词元；长候选自动缩小并行组以免越过固定批次容量，超限会明确失败。模型需留有额外内存。候选编号顺序不参与分数，完全同分时按文字稳定排序。

## 复现实验

```sh
python3 -m unittest discover -s scripts/ai-writing-decoder -p 'test_*.py' -v

python3 scripts/ai-writing-decoder/benchmark.py \
  --output .build/ai-writing-decoder-runs/run-001.json -- \
  --grammar-file /absolute/path/to/wanxiang-lts-zh-hans.gram \
  --rime-plugin /absolute/path/to/librime-octagram.dylib \
  --model-path /absolute/path/to/model.gguf \
  --backend-directory /absolute/path/to/llama.cpp/build/bin \
  --score-layout prose --diagnostics
```

`cases-for-review.json` 中的参考答案仅供评审。基准程序通过字段白名单构造请求，`decode.py` 也拒绝接收参考答案。运行前记录源码及请求哈希，不覆盖已有结果。每条输出仍需核对读音、原意、既有中文、否定、英文、数字和手动分隔。37 个样本包含 25 条已有诊断输入和 12 条新增输入，其中有同句的正确/错拼配对；这不是独立的大规模准确率评估。

当前比较和逐条复核见 [实验记录](../../docs/ai-writing-decoder-experiment.md)。
