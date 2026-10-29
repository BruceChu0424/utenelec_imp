import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-contract evidence only. Windows cannot compile the Apple/Linux/Android
/// runners; these checks do not stand in for native compilation or device UAT.
void main() {
  test(
    'new native host branches precede staging and leave old update context intact',
    () {
      for (final path in [
        'android/app/src/main/kotlin/com/uten/uten_imp/ClientUpdateBridge.kt',
        'ios/Runner/AppDelegate.swift',
        'macos/Runner/MainFlutterWindow.swift',
        'linux/runner/my_application.cc',
      ]) {
        final source = File(path).readAsStringSync();
        final start = source.indexOf('"getSoftwareDownloadHost"');
        final update = source.indexOf('"getInstallContext"', start);
        expect(start, greaterThanOrEqualTo(0), reason: path);
        expect(update, greaterThan(start), reason: path);
        final host = source.substring(start, update);
        for (final mutation in [
          'stagingDirectory()',
          'createDirectory(',
          'g_mkdir',
          'ProcessBuilder',
          'system(',
        ]) {
          expect(
            host,
            isNot(contains(mutation)),
            reason: '$path: host must not $mutation',
          );
        }
        expect(
          source.substring(update),
          contains('stagingDirectory'),
          reason: '$path: old updater context remains',
        );
      }
    },
  );
  test(
    'native facts use OS ABI, Rosetta and simulator evidence, not compilation architecture',
    () {
      final android = File(
        'android/app/src/main/kotlin/com/uten/uten_imp/ClientUpdateBridge.kt',
      ).readAsStringSync();
      expect(android, contains('Build.SUPPORTED_64_BIT_ABIS'));
      final mac = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      expect(mac, contains('sysctl.proc_translated'));
      expect(mac, contains('hw.optional.arm64'));
      expect(mac, contains('MemoryLayout.size(ofValue: system.machine)'));
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      expect(ios, contains('targetEnvironment(simulator)'));
      expect(ios, contains('"isSimulator": simulator'));
      final linux = File('linux/runner/my_application.cc').readAsStringSync();
      expect(linux, contains('uname(&system)'));
    },
  );
}
