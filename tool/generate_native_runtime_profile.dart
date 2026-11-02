import 'dart:convert';
import 'dart:io';

import 'package:uten_imp/core/runtime/client_runtime_profile.dart';

void main(List<String> args) {
  final options = <String, String>{};
  for (final arg in args) {
    final split = arg.indexOf('=');
    if (!arg.startsWith('--') || split < 0) {
      throw ArgumentError('Named arguments required');
    }
    options[arg.substring(2, split)] = arg.substring(split + 1);
  }
  final defines = <String, String>{};
  for (final encoded in (options['dart-defines'] ?? '').split(',')) {
    if (encoded.isEmpty) continue;
    final decoded = utf8.decode(base64.decode(base64.normalize(encoded)));
    final split = decoded.indexOf('=');
    if (split < 0) throw const FormatException('Invalid Dart define');
    final key = decoded.substring(0, split),
        value = decoded.substring(split + 1);
    if (defines.containsKey(key) && defines[key] != value) {
      throw FormatException('Conflicting Dart define: $key');
    }
    defines[key] = value;
  }
  final flag = defines['UTEN_LOCAL_TEST'] ?? 'false';
  if (!const {'true', 'false'}.contains(flag)) {
    throw const FormatException('Invalid UTEN_LOCAL_TEST');
  }
  final profile = ClientRuntimeProfile(localTest: flag == 'true');
  profile.validateConfiguration(
    local: defines['API_BASE_URL'] ?? '',
    cloud: defines['CLOUD_API_BASE_URL'] ?? '',
    controlPlane: defines['DR_CONTROL_PLANE_URL'] ?? '',
  );
  for (final pair in [
    (options['header'], profile.toNativeHeader()),
    (
      options['manifest'],
      '${const JsonEncoder.withIndent('  ').convert(profile.toMetadata())}\n',
    ),
  ]) {
    final path = pair.$1;
    if (path == null) continue;
    final file = File(path);
    file.parent.createSync(recursive: true);
    if (!file.existsSync() || file.readAsStringSync() != pair.$2) {
      file.writeAsStringSync(pair.$2);
    }
  }
  stdout.write(profile.buildProfile);
}
