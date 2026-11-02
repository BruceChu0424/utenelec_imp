import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../io/client_private_paths.dart';
import '../network/api_endpoint_configuration.dart';
import 'client_runtime_profile.dart';
import 'bootstrap_trace.dart';

/// Metadata only: never inspect an account/token/draft from another profile.
Future<void> verifyLocalTestStorage() async {
  const profile = ClientRuntimeProfile.current;
  if (!profile.localTest) return;
  recordLocalBootstrapPhase('private_paths.support.begin');
  final support = await getApplicationSupportDirectory();
  recordLocalBootstrapPhase('private_paths.support.end');
  final segments = support.uri.pathSegments
      .where((part) => part.isNotEmpty)
      .toList();
  final isolated = Platform.isWindows
      ? segments.last.toLowerCase() == profile.nativeProductName.toLowerCase()
      : Platform.isAndroid && segments.contains(profile.applicationId);
  recordLocalBootstrapPhase('private_paths.support.leaf.${segments.last}');
  if (!isolated) {
    throw StateError('LocalTest private storage identity mismatch.');
  }
  recordLocalBootstrapPhase('private_paths.cache.begin');
  final cache = await getApplicationCacheDirectory();
  recordLocalBootstrapPhase('private_paths.cache.end');
  final temporary = await getTemporaryDirectory();
  recordLocalBootstrapPhase('private_paths.temp.end');
  final exports = await getApplicationDocumentsDirectory();
  recordLocalBootstrapPhase('private_paths.exports.end');
  String? nativeLogs;
  if (Platform.isWindows) {
    nativeLogs = await const MethodChannel(
      'com.uten.imp/diagnostics',
    ).invokeMethod<String>('getLogDirectory');
    recordLocalBootstrapPhase('private_paths.native_logs.end');
    if (nativeLogs == null || !nativeLogs.contains(profile.applicationId)) {
      throw StateError('LocalTest native log storage identity mismatch.');
    }
  }
  await File('${support.path}/localtest-runtime-receipt.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      ...profile.toMetadata(),
      'apiBaseUrl': configuredLocalApiBaseUrl,
      'cloudApiBaseUrl': configuredCloudApiBaseUrl,
      'controlPlaneEnabled': false,
      'applicationSupport': support.path,
      'applicationCache': cache.path,
      'temporaryCache': temporary.path,
      'exportDirectory': exports.path,
      'nativeLogs': nativeLogs,
      'preferencesAndSecureStoreRoot': support.path,
      'localDatabase': 'backend API only',
      'credentialContentsInspected': false,
    }),
    flush: true,
  );
  recordLocalBootstrapPhase('private_paths.receipt.end');
}
