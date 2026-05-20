# Third-Party Notices

Typeforme source code is licensed under the Apache License 2.0 unless a file
states otherwise. This document summarizes notable third-party components used
by the project or expected for optional local runtimes. Binary distributions
should include the applicable upstream license texts and attribution notices.

## Swift Package Dependencies

- KeyboardShortcuts: MIT License
  - https://github.com/sindresorhus/KeyboardShortcuts
- Argmax OSS Swift / WhisperKit: MIT License
  - https://github.com/argmaxinc/argmax-oss-swift
- Hummingbird: Apache License 2.0
  - https://github.com/hummingbird-project/hummingbird
- Swift Server and Apple Swift packages, including SwiftNIO, AsyncHTTPClient,
  swift-crypto, swift-log, swift-collections, swift-algorithms, and related
  transitive packages: Apache License 2.0
  - https://github.com/apple/swift-nio
  - https://github.com/swift-server/async-http-client
  - https://github.com/apple/swift-crypto

## Bundled Local Runtime

- llama.cpp / ggml runtime files, when copied into `vendor/` and bundled into
  `dist/Typeforme.app`: MIT License
  - https://github.com/ggml-org/llama.cpp
- OpenSSL libraries may be included by the local llama runtime build:
  Apache License 2.0
  - https://www.openssl.org/

## Planned Rime Integration

Typeforme's Rime integration is planned around librime and Typeforme-owned
wrapper code under the current Apache-2.0 licensing model.

- librime: BSD 3-Clause License
  - https://github.com/rime/librime
- Rime runtime dependencies may include Boost, LevelDB, marisa-trie, OpenCC,
  yaml-cpp, and related libraries. Preserve their upstream license texts when
  bundling binary releases.
- Squirrel, ibus-rime, and other official Rime frontends are GPL-3.0 projects.
  They are excluded from Typeforme-owned source and binary distributions unless
  the project is intentionally relicensed under a GPL-compatible distribution
  model.
- plum, rime-essay, and many Rime schema/configuration repositories are
  LGPL-3.0. If bundled, they should be distributed as clearly separated
  third-party assets with their upstream license texts and attribution notices.

## Models and User-Provided Assets

Model files, prompts, schemas, dictionaries, and user-provided configuration may
have separate licenses. Downloaded or user-installed assets are governed by
their own license terms unless those assets explicitly state otherwise.
