import 'dart:convert';
import 'dart:io';

const String _platform = 'windows';

Future<int> run(List<String> args) async {
  final _Options options = _Options.parse(args);
  if (options.help) {
    _printUsage();
    return 0;
  }
  if (options.error != null) {
    _error(options.error!);
    _printUsage();
    return 64;
  }

  if (!Platform.isWindows && !options.dryRun) {
    _error(
      'This tool repairs Flutter Windows plugin links and must be run on Windows.',
    );
    return 1;
  }

  final Directory projectDir = Directory.current.absolute;
  final File dependencyFile = File(
    '${projectDir.path}${Platform.pathSeparator}.flutter-plugins-dependencies',
  );
  final Directory windowsDir = Directory(
    '${projectDir.path}${Platform.pathSeparator}windows',
  );
  final Directory linkRoot = Directory(
    '${windowsDir.path}${Platform.pathSeparator}flutter'
    '${Platform.pathSeparator}ephemeral'
    '${Platform.pathSeparator}.plugin_symlinks',
  );

  stdout.writeln('Project : ${projectDir.path}');
  stdout.writeln('Links   : ${linkRoot.path}');
  if (options.dryRun) {
    stdout.writeln('Mode    : dry run');
  }
  stdout.writeln('');

  if (!dependencyFile.existsSync()) {
    _error(
      'Missing ${dependencyFile.path}.\n'
      'Run "flutter pub get" or "fvm flutter pub get" in the project first.',
    );
    return 1;
  }

  final List<PluginDependency> plugins;
  try {
    plugins =
        readPluginsFromDependencyContent(dependencyFile.readAsStringSync());
  } on FormatException catch (e) {
    _error('${dependencyFile.path}: ${e.message}');
    return 1;
  }
  if (plugins.isEmpty) {
    stdout.writeln('No Windows plugins found. Nothing to repair.');
    return 0;
  }

  if (!linkRoot.existsSync()) {
    if (options.dryRun) {
      stdout.writeln('[create] ${linkRoot.path}');
    } else {
      linkRoot.createSync(recursive: true);
    }
  }

  int repaired = 0;
  int failed = 0;

  for (final PluginDependency plugin in plugins) {
    final Directory link = Directory(
      '${linkRoot.path}${Platform.pathSeparator}${plugin.name}',
    );
    final Directory target = Directory(plugin.path);

    if (!target.existsSync()) {
      failed++;
      _warn('${plugin.name}: target does not exist: ${target.path}');
      continue;
    }

    final Directory platformDir = Directory(
      '${target.path}${Platform.pathSeparator}$_platform',
    );
    if (plugin.nativeBuild && !platformDir.existsSync()) {
      _warn(
        '${plugin.name}: native_build=true but ${platformDir.path} is missing; '
        'the junction will still be rebuilt to the package root.',
      );
    }

    stdout.writeln('[repair] ${plugin.name}');
    stdout.writeln('         ${link.path}');
    stdout.writeln('      -> ${target.path}');

    if (options.dryRun) {
      repaired++;
      continue;
    }

    final bool removed = await _removeLinkOrDirectory(link);
    if (!removed) {
      failed++;
      _warn('${plugin.name}: failed to remove existing link/directory.');
      continue;
    }

    final bool created = await _createJunction(link, target);
    if (!created) {
      failed++;
      continue;
    }

    if (!_linkLooksUsable(link, target)) {
      failed++;
      _warn('${plugin.name}: junction was created but validation failed.');
      continue;
    }

    repaired++;
  }

  stdout.writeln('');
  stdout.writeln('Done. repaired=$repaired failed=$failed');

  return failed > 0 ? 1 : 0;
}

List<PluginDependency> readPluginsFromDependencyContent(String content) {
  final Object? decoded = jsonDecode(content);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Invalid .flutter-plugins-dependencies JSON.');
  }

  final Object? plugins = decoded['plugins'];
  if (plugins is! Map<String, Object?>) {
    throw const FormatException('Missing "plugins" map.');
  }

  final Object? platformPlugins = plugins[_platform];
  if (platformPlugins == null) {
    return const <PluginDependency>[];
  }
  if (platformPlugins is! List<Object?>) {
    throw const FormatException('Invalid plugins.windows list.');
  }

  final List<PluginDependency> result = <PluginDependency>[];
  for (final Object? item in platformPlugins) {
    if (item is! Map<String, Object?>) {
      continue;
    }
    final Object? name = item['name'];
    final Object? path = item['path'];
    if (name is! String || name.isEmpty || path is! String || path.isEmpty) {
      continue;
    }
    result.add(
      PluginDependency(
        name: name,
        path: normalizeWindowsPath(path),
        nativeBuild: item['native_build'] == true,
      ),
    );
  }
  return result;
}

String normalizeWindowsPath(String path) {
  String value = path.trim().replaceAll('/', r'\');
  final String uncPrefix = value.startsWith(r'\\') ? r'\\' : '';
  if (uncPrefix.isNotEmpty) {
    value = value.substring(2);
  }
  value = value.replaceAll(RegExp(r'\\+'), r'\');
  value = '$uncPrefix$value';
  while (value.endsWith(r'\') || value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

bool _linkLooksUsable(Directory link, Directory expectedTarget) {
  if (!link.existsSync()) {
    return false;
  }

  final File pubspec = File(
    '${link.path}${Platform.pathSeparator}pubspec.yaml',
  );
  if (!pubspec.existsSync()) {
    return false;
  }

  final File targetPubspec = File(
    '${expectedTarget.path}${Platform.pathSeparator}pubspec.yaml',
  );
  if (!targetPubspec.existsSync()) {
    return false;
  }

  try {
    return pubspec.resolveSymbolicLinksSync() ==
        targetPubspec.resolveSymbolicLinksSync();
  } on FileSystemException {
    return false;
  }
}

Future<bool> _removeLinkOrDirectory(Directory link) async {
  if (!FileSystemEntity.isDirectorySync(link.path) &&
      !FileSystemEntity.isLinkSync(link.path)) {
    return true;
  }

  final ProcessResult result = await Process.run(
      'cmd',
      <String>[
        '/c',
        'rmdir',
        link.path,
      ],
      runInShell: false);
  if (result.exitCode == 0 || !link.existsSync()) {
    return true;
  }

  try {
    link.deleteSync(recursive: false);
    return true;
  } on FileSystemException {
    return false;
  }
}

Future<bool> _createJunction(Directory link, Directory target) async {
  final ProcessResult result = await Process.run(
      'cmd',
      <String>[
        '/c',
        'mklink',
        '/J',
        link.path,
        target.path,
      ],
      runInShell: false);

  if (result.exitCode == 0) {
    return true;
  }

  stderr.writeln(
    '[error] mklink failed for ${link.path}\n'
    '${result.stdout}${result.stderr}',
  );
  return false;
}

void _warn(String message) {
  stderr.writeln('[warn] $message');
}

void _error(String message) {
  stderr.writeln('[error] $message');
}

void _printUsage() {
  stdout.writeln('''
Repair Flutter Windows plugin links by rebuilding .plugin_symlinks as junctions.

Usage:
  dart run win_plugin_link_repair
  dart run win_plugin_link_repair --dry-run

Options:
  --dry-run   Print actions without changing files.
  -h, --help  Show this help.

Notes:
  Run this command from the Flutter project root.
  Run flutter pub get first so .flutter-plugins-dependencies is current.
''');
}

final class PluginDependency {
  const PluginDependency({
    required this.name,
    required this.path,
    required this.nativeBuild,
  });

  final String name;
  final String path;
  final bool nativeBuild;
}

final class _Options {
  const _Options({
    required this.dryRun,
    required this.help,
    this.error,
  });

  final bool dryRun;
  final bool help;
  final String? error;

  factory _Options.parse(List<String> args) {
    bool dryRun = false;
    bool help = false;

    for (final String arg in args) {
      switch (arg) {
        case '--dry-run':
          dryRun = true;
        case '-h':
        case '--help':
          help = true;
        default:
          return _Options(
            dryRun: dryRun,
            help: help,
            error: 'Unknown argument: $arg',
          );
      }
    }

    return _Options(dryRun: dryRun, help: help);
  }
}
