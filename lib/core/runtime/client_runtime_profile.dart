import 'dart:convert';

/// One build-owned profile shared by Dart and generated native identities.
/// It is never selected from preferences, a server response or a route.
class ClientRuntimeProfile {
  const ClientRuntimeProfile({required this.localTest});

  static const isLocalTest = bool.fromEnvironment('UTEN_LOCAL_TEST');
  static const current = ClientRuntimeProfile(localTest: isLocalTest);
  static const formalApplicationId = 'com.uten.uten_imp';
  static const localApplicationId = 'com.uten.uten_imp.local_test';
  static const formalProductName = '优腾综合管理平台';
  static const localProductName = 'UTEN Local Test';
  static const formalDisplayName = 'UTEN';
  static const localDisplayName = 'UTEN 本地测试';

  final bool localTest;
  String get buildProfile => localTest ? 'local_test' : 'formal';
  String get applicationId =>
      localTest ? localApplicationId : formalApplicationId;
  String get nativeProductName =>
      localTest ? localProductName : formalProductName;
  String get displayName => localTest ? localDisplayName : formalDisplayName;
  bool get selfUpdatesAllowed => !localTest;

  static bool isLoopback(Uri uri) =>
      const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host.toLowerCase());

  Uri localApi(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        !isLoopback(uri) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.replaceAll(RegExp(r'/+$'), '') != '/api') {
      throw StateError(
        'LocalTest requires an explicit loopback /api endpoint.',
      );
    }
    return uri.replace(path: '/api');
  }

  void validateConfiguration({
    required String local,
    required String cloud,
    required String controlPlane,
  }) {
    if (!localTest) return;
    final api = localApi(local);
    if (cloud.trim().isNotEmpty && localApi(cloud) != api) {
      throw StateError('LocalTest cloud endpoint must equal its loopback API.');
    }
    if (controlPlane.trim().isNotEmpty) {
      throw StateError('LocalTest cannot configure an external control plane.');
    }
  }

  bool allowsNetworkUri(Uri uri, {required Uri localApi}) =>
      !localTest ||
      (uri.userInfo.isEmpty &&
          isLoopback(uri) &&
          uri.scheme == localApi.scheme &&
          uri.host.toLowerCase() == localApi.host.toLowerCase() &&
          uri.port == localApi.port);

  bool allowsExternalUri(Uri uri, {required Uri localApi}) =>
      !localTest ||
      (uri.scheme == 'file' && (uri.host.isEmpty || uri.host == 'localhost')) ||
      allowsNetworkUri(uri, localApi: localApi);

  String visibleTitle(String title) =>
      !localTest || title.startsWith(displayName)
      ? title
      : '$displayName · $title';

  Map<String, Object> toMetadata() => {
    'schemaVersion': 1,
    'buildProfile': buildProfile,
    'applicationId': applicationId,
    'nativeProductName': nativeProductName,
    'displayName': displayName,
    'runtimeFamily': 'flutter',
    'networkScope': localTest ? 'loopback-only' : 'trusted-configured',
    'selfUpdatesAllowed': selfUpdatesAllowed,
  };

  String toNativeHeader() =>
      '''// Generated from client_runtime_profile.dart. Do not edit.
#pragma once
#define UTEN_LOCAL_TEST_BUILD ${localTest ? 1 : 0}
#define UTEN_BUILD_PROFILE ${jsonEncode(buildProfile)}
#define UTEN_APPLICATION_ID ${jsonEncode(applicationId)}
#define UTEN_NATIVE_PRODUCT_NAME ${jsonEncode(nativeProductName)}
#define UTEN_DISPLAY_NAME ${jsonEncode(displayName)}
#define UTEN_DISPLAY_NAME_W L${jsonEncode(displayName)}
''';
}
