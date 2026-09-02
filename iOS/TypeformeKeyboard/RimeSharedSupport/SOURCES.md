# Rime Shared Support

This directory contains the Rime source data and generated runtime data used by
the Typeforme iOS keyboard extension. Xcode stages a runtime-only subset into
the built `.appex`; source Chinese dictionaries and local user state are not
copied into the keyboard bundle.

- `typeforme_pinyin*.schema.yaml`, `typeforme_pinyin*.dict.yaml`,
  `typeforme_overrides.dict.yaml`, and `default.yaml` are Typeforme
  integration files that configure librime for the screen keyboard.
- `scripts/build-rime-ios-data.sh` generates no-correction schema variants
  from the three checked-in pinyin schemas before building prebuilt data.
- `scripts/stage-rime-ios-runtime.sh` copies the runtime subset required by
  librime into the built keyboard extension. It includes top-level Typeforme
  schema/dictionary files and generated `build/` files, but excludes
  `cn_dicts/` source dictionaries and mutable user data.
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
Chinese mode uses pinyin candidates without an English translator. Space
confirms the default candidate; Return preserves any confirmed Chinese prefix
and commits the remaining raw input without adding a space or newline. With no
active composition, Return performs the host field's normal action. Use
English mode for direct English typing; URL/email fields and explicit URL/email
tokens retain their literal-input handling.
