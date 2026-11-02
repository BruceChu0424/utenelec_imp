import 'dart:convert';
import 'dart:io';
import 'client_runtime_profile.dart';

final _watch = Stopwatch()..start();

void recordLocalBootstrapPhase(String phase) {
  if (!ClientRuntimeProfile.isLocalTest || !Platform.isWindows) return;
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null) return;
  try {
    final root = Directory(
      '$local/${ClientRuntimeProfile.current.applicationId}/bootstrap',
    )..createSync(recursive: true);
    File('${root.path}/bootstrap-$pid.log').writeAsStringSync(
      '${jsonEncode({'schemaVersion': 1, 'atUtc': DateTime.now().toUtc().toIso8601String(), 'phase': phase, 'elapsedMs': _watch.elapsedMilliseconds})}\n',
      mode: FileMode.append,
      flush: true,
    );
  } on FileSystemException {
    // A diagnostic disk failure cannot prevent the visible isolation gate.
  }
}
