# Building

## Native core and tests

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j
    ctest --test-dir build --output-on-failure

The tests include `translations`, which fails if any `tr('...')` key used in `ui/lib/*.dart` or any native `Key::...` is missing from `i18n/translations/*.json`, or if the generated files are stale.

## Windows from Linux (zig)

    cmake -S . -B build-win -G Ninja -DCMAKE_TOOLCHAIN_FILE=$PWD/tools/zig/windows.cmake -DCMAKE_BUILD_TYPE=Release
    cmake --build build-win -j

## Translations

    python tools/lang.py sync
    python tools/check_i18n.py

See [CONTRIBUTING.md](../CONTRIBUTING.md) to add a language.

## UI

    cd ui
    flutter pub get
    flutter analyze
    flutter test
