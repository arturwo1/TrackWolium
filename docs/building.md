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

## CI

`.github/workflows/ci.yml` builds and tests on Windows, Linux and macOS, builds the Android library and the Flutter UI for Linux, Android and macOS. Releases are built from a `v*` tag by `release.yml`.

## Store builds

- `-DTW_STORE_BUILD=ON` (CMake) and `--dart-define=STORE_BUILD=true` (Flutter) remove the GitHub updater. On Android, `STORE_BUILD=true` for `tool/patch_android.py` also drops `REQUEST_INSTALL_PACKAGES` and marks the app so the background update worker does nothing.
- `tools/msix/make_msix.py` writes `AppxManifest.xml` (`runFullTrust`, a `StartupTask`) and packs `Wolium.msix` with `makeappx`. Set the repository variables `MSIX_IDENTITY` and `MSIX_PUBLISHER` to the values from Partner Center. The package is unsigned, the Store signs it.
- `Wolium.aab` is built by `flutter build appbundle` and signed with the same keystore as the APK.
