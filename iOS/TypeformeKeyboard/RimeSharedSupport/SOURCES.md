# Rime Shared Support

This directory contains the minimal Rime runtime data used by the Typeforme
iOS keyboard extension.

- `typeforme_pinyin*.schema.yaml`, `typeforme_pinyin*.dict.yaml`,
  `typeforme_overrides.dict.yaml`, and `default.yaml` are Typeforme integration
  files that configure librime for the screen keyboard.
- `cn_dicts/8105.dict.yaml`, `cn_dicts/base.dict.yaml`,
  `cn_dicts/ext.dict.yaml`, `cn_dicts/tencent.dict.yaml`, and
  `LICENSE.rime-ice.txt` are copied from `iDvel/rime-ice` and are distributed
  under GPL-3.0 only.

Generated Rime build outputs are intentionally not committed. Before building
the iOS keyboard with Chinese input enabled, run:

```sh
scripts/build-rime-ios-data.sh
```

That creates `build/` from the files above with `rime_deployer`, so the
keyboard extension can load candidates without compiling dictionaries on first
use.

To inspect the candidate quality from the same prebuilt data used by the iOS
keyboard, run:

```sh
scripts/benchmark-rime-ios-data.sh
```

The keyboard code does not contain a local pinyin table. Key events are routed
to librime, and candidates/commit text are read back from the Rime session.
