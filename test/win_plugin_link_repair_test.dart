import 'dart:convert';

import 'package:test/test.dart';
import 'package:win_plugin_link_repair/win_plugin_link_repair.dart';

void main() {
  test('reads Windows plugins from Flutter dependency metadata', () {
    final String content = jsonEncode(<String, Object?>{
      'plugins': <String, Object?>{
        'windows': <Object?>[
          <String, Object?>{
            'name': 'camera_windows',
            'path': r'C:/Users/me/AppData/Local/Pub/Cache/camera_windows',
            'native_build': true,
          },
          <String, Object?>{
            'name': 'bad_plugin',
          },
        ],
        'android': <Object?>[
          <String, Object?>{
            'name': 'camera_android',
            'path': '/tmp/camera_android',
          },
        ],
      },
    });

    final List<PluginDependency> plugins = readPluginsFromDependencyContent(
      content,
    );

    expect(plugins, hasLength(1));
    expect(plugins.single.name, 'camera_windows');
    expect(
      plugins.single.path,
      r'C:\Users\me\AppData\Local\Pub\Cache\camera_windows',
    );
    expect(plugins.single.nativeBuild, isTrue);
  });

  test('returns empty list when there are no Windows plugins', () {
    final String content = jsonEncode(<String, Object?>{
      'plugins': <String, Object?>{
        'android': <Object?>[],
      },
    });

    expect(readPluginsFromDependencyContent(content), isEmpty);
  });

  test('normalizes Windows path slashes and trailing separators', () {
    expect(normalizeWindowsPath(r'C:/tmp//plugin///'), r'C:\tmp\plugin');
    expect(normalizeWindowsPath(r'\\server//share/plugin/'),
        r'\\server\share\plugin');
  });
}
