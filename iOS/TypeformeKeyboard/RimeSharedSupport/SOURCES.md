# Rime Shared Support

This directory contains the minimal Rime runtime data used by the Typeforme
iOS keyboard extension.

- `typeforme_pinyin*.schema.yaml`, `typeforme_pinyin*.dict.yaml`,
  `typeforme_overrides.dict.yaml`, `typeforme_english.schema.yaml`,
  and `default.yaml` are Typeforme integration files that configure librime
  for the screen keyboard.
- `typeforme_english.dict.yaml` combines Typeforme-curated product/technical
  terms with lowercase ASCII words generated from `en_US.txt` in
  `en-wl/wordlist-diff` commit
  `1f8ccc65c6d97ca201522e5bbb9fa05c80139bdc`. ESDB is Copyright 2000-2026
  by Kevin Atkinson and permits use, modification, distribution, and sale of
  generated word lists when the copyright and permission notice are preserved;
  ESDB is provided "as is" without express or implied warranty.
- `scripts/build-rime-ios-data.sh` generates no-correction schema variants
  from the three checked-in pinyin schemas before building prebuilt data.
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
