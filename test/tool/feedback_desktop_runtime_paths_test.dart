import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/runtime/client_runtime_profile.dart';

import '../../tool/feedback_desktop_runtime_paths.dart';

void main() {
  final workspace = Directory.current.absolute;
  final owned = Directory(
    '${workspace.path}/evidence/desktop-path-check/private/windows-runtime',
  )..createSync(recursive: true);
  const local = ClientRuntimeProfile(localTest: true);
  const formal = ClientRuntimeProfile.current;

  test('ordinary formal and local builds retain their existing log paths', () {
    for (final profile in [local, formal]) {
      expect(
        feedbackDesktopNativeLogDirectory(
          defines: const {},
          profile: profile,
          workspace: workspace,
        ),
        isNull,
      );
    }
  });
  test(
    'only build-owned private evidence can isolate native acceptance logs',
    () {
      final path = feedbackDesktopNativeLogDirectory(
        defines: {'UTEN_FEEDBACK_RUNTIME_ROOT': owned.path},
        profile: local,
        workspace: workspace,
      );
      expect(path, startsWith(owned.resolveSymbolicLinksSync()));
      expect(path, contains(local.applicationId));
    },
  );
  test('formal, relative and non-evidence directories are rejected', () {
    for (final input in [
      (formal, owned.path),
      (local, 'evidence/relative/private/windows-runtime'),
      (local, workspace.path),
    ]) {
      expect(
        () => feedbackDesktopNativeLogDirectory(
          defines: {'UTEN_FEEDBACK_RUNTIME_ROOT': input.$2},
          profile: input.$1,
          workspace: workspace,
        ),
        throwsFormatException,
      );
    }
  });
}
