# win_plugin_link_repair

Repair Flutter Windows plugin links by rebuilding
`windows/flutter/ephemeral/.plugin_symlinks` entries as Windows junctions.

This is a small Dart CLI tool for Flutter Windows projects. It reads
`.flutter-plugins-dependencies`, finds `plugins.windows`, removes the generated
plugin link entries, and recreates them with `mklink /J`.

## Install

```bash
dart pub add --dev win_plugin_link_repair
```

## Use

Run it from the Flutter project root:

```bash
dart run win_plugin_link_repair
```

Preview the actions without changing files:

```bash
dart run win_plugin_link_repair --dry-run
```

## Notes

- Run `flutter pub get` first so `.flutter-plugins-dependencies` is current.
- Actual repair must run on Windows.
- The tool uses junctions to avoid Windows symlink permission requirements.
