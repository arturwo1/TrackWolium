# Contributing

Thanks for helping with Wolium. The project is proprietary (see `LICENSE`), but forks made to contribute back are explicitly allowed (section 3), and community help is welcome in three forms:

- bug reports (open an issue with steps, OS version and the app version from Settings)
- improvements: fork the repository, make a focused change, open a pull request
- translations

By opening a pull request you agree to the contribution license in section 3 of `LICENSE`. You keep the copyright in your work. Do not publish releases or installers from your fork and do not present it as an official product.

## Add a translation

    python tools/lang.py add <code> <Name> [windows_primary_langid]
    python tools/lang.py sync

1. Run the first command, for example `python tools/lang.py add de Deutsch 0x07`.
2. Open `i18n/translations/<code>.json` and translate the values. Do not rename keys. Keep `%` and `{}` placeholders and line breaks as they are. Untranslated keys fall back to English.
3. Run the second command and commit the changed files.

No code needs to be edited by hand.

## Code rules

- 2-space indentation, no comments in code
- no user-facing text in code, only translation keys
- the product name is always "Wolium"
- keep background disk activity at zero: no periodic writes outside the batched flush
- run the tests before opening a pull request: `cmake -S . -B build && cmake --build build && ctest --test-dir build`

Technical notes for contributors: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
