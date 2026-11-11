import 'dart:io';

import 'package:uten_imp/core/runtime/client_runtime_profile.dart';

/// Build-time acceptance metadata only. No runtime argument or business input
/// can choose a directory. Native use is separately gated by Debug + LocalTest.
String? feedbackDesktopNativeLogDirectory({
  required Map<String, String> defines,
  required ClientRuntimeProfile profile,
  required Directory workspace,
}) {
  final raw = defines['UTEN_FEEDBACK_RUNTIME_ROOT'];
  if (raw == null || raw.isEmpty) return null;
  if (!profile.localTest) {
    throw const FormatException('Feedback paths require LocalTest');
  }
  final requested = Directory(raw);
  if (!requested.isAbsolute || !requested.existsSync()) {
    throw const FormatException(
      'An existing absolute feedback root is required',
    );
  }
  String normalized(String path) {
    final value = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  final owner = normalized(workspace.resolveSymbolicLinksSync());
  final canonical = requested.resolveSymbolicLinksSync();
  final checked = normalized(canonical);
  if (!checked.startsWith('$owner/evidence/') ||
      !checked.endsWith('/private/windows-runtime')) {
    throw const FormatException(
      'Feedback root must be in owned private evidence',
    );
  }
  return '$canonical/${profile.applicationId}/client-logs/flutter/debug-feedback';
}
