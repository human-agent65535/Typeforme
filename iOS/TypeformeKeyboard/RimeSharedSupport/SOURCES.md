# Rime Shared Support

This directory contains the minimal Rime runtime data used by the Typeforme
iOS keyboard extension.

- `typeforme_pinyin.schema.yaml` and `default.yaml` are Typeforme integration
  files that configure librime for the screen keyboard.
- `pinyin_simp.dict.yaml` and `LICENSE.rime-pinyin-simp.txt` are copied from
  `rime/rime-pinyin-simp` and are distributed under Apache License 2.0.

Generated Rime build outputs are intentionally not committed. Before building
the iOS keyboard with Chinese input enabled, run:

```sh
scripts/build-rime-ios-data.sh
```

That creates `build/` from the files above with `rime_deployer`, so the
keyboard extension can load candidates without compiling dictionaries on first
use.

The keyboard code does not contain a local pinyin table. Key events are routed
to librime, and candidates/commit text are read back from the Rime session.
