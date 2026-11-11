import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

import '../support/windows_acceptance_preferences.dart';

class _NotWindowsPreferences extends SharedPreferencesStorePlatform {
  @override
  Future<Map<String, Object>> getAll() => throw StateError('Unexpected read');
  @override
  Future<bool> clear() => throw StateError('Unexpected clear');
  @override
  Future<bool> remove(String key) => throw StateError('Unexpected remove');
  @override
  Future<bool> setValue(String type, String key, Object value) =>
      throw StateError('Unexpected write');
}

void main() {
  test(
    'both real Windows preference stores write only the explicit private root',
    () async {
      final oldLegacy = SharedPreferencesStorePlatform.instance;
      final oldAsync = SharedPreferencesAsyncPlatform.instance;
      final root = Directory(
        '${Directory.current.path}/evidence/prefs-contract-${DateTime.now().microsecondsSinceEpoch}/private/windows-runtime',
      )..createSync(recursive: true);
      try {
        SharedPreferencesWindows.registerWith();
        isolateRealWindowsPreferences(root);
        final legacy =
            SharedPreferencesStorePlatform.instance as SharedPreferencesWindows;
        final asynchronous =
            SharedPreferencesAsyncPlatform.instance!
                as SharedPreferencesAsyncWindows;
        expect(await legacy.getAll(), isEmpty);
        await legacy.setValue(
          'String',
          'flutter.acceptance_probe',
          'private-legacy',
        );
        expect(
          (await legacy.getAll())['flutter.acceptance_probe'],
          'private-legacy',
        );
        const options = SharedPreferencesOptions();
        await asynchronous.setString(
          'acceptance_async_probe',
          'private-async',
          options,
        );
        expect(
          await asynchronous.getString('acceptance_async_probe', options),
          'private-async',
        );
        final file = File(
          '${root.path}/UTEN Local Test/shared_preferences.json',
        );
        expect(file.existsSync(), isTrue);
        final ownContents = await file.readAsString();
        expect(ownContents, contains('private-legacy'));
        expect(ownContents, contains('private-async'));
      } finally {
        SharedPreferencesStorePlatform.instance = oldLegacy;
        SharedPreferencesAsyncPlatform.instance = oldAsync;
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'an unregistered Windows backend fails before any preference file access',
    () {
      final old = SharedPreferencesStorePlatform.instance;
      final root = Directory(
        '${Directory.current.path}/evidence/prefs-rejected-${DateTime.now().microsecondsSinceEpoch}/private/windows-runtime',
      );
      try {
        SharedPreferencesStorePlatform.instance = _NotWindowsPreferences();
        expect(() => isolateRealWindowsPreferences(root), throwsStateError);
        expect(root.existsSync(), isFalse);
      } finally {
        SharedPreferencesStorePlatform.instance = old;
      }
    },
    skip: !Platform.isWindows,
  );
}
