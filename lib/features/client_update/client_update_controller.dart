import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../shared/providers/session_provider.dart';
import 'client_package_download.dart';
import 'client_release.dart';
import 'client_update_bridge.dart';

enum ClientUpdateStage {
  idle,
  checking,
  available,
  downloading,
  installing,
  installerOpened,
  failed,
}

final clientUpdateControllerProvider = Provider<ClientUpdateController>((ref) {
  ref.watch(sessionProvider.select((s) => (s.status, s.user?.id, s.actor?.id)));
  final controller = ClientUpdateController(
    api: ref.watch(apiClientProvider),
    bridge: ClientUpdateBridge(),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

class ClientUpdateController extends ChangeNotifier {
  ClientUpdateController({required this.api, required this.bridge});
  final ApiClient api;
  final ClientUpdateBridge bridge;
  ClientInstallContext? installed;
  ClientRelease? release;
  ClientUpdateStage stage = ClientUpdateStage.idle;
  Object? error;
  double progress = 0;
  bool hasSuccessfulCheck = false;
  DateTime? lastCheckedAt;
  int checkIntervalSeconds = 300;
  bool _disposed = false;
  final _ownerDisposedListeners = <VoidCallback>{};
  CancelToken? _download;
  bool get isDisposed => _disposed;
  void addOwnerDisposedListener(VoidCallback listener) =>
      _ownerDisposedListeners.add(listener);
  void removeOwnerDisposedListener(VoidCallback listener) =>
      _ownerDisposedListeners.remove(listener);
  bool get busy =>
      stage == ClientUpdateStage.checking ||
      stage == ClientUpdateStage.downloading ||
      stage == ClientUpdateStage.installing;
  bool get transferBusy =>
      stage == ClientUpdateStage.downloading ||
      stage == ClientUpdateStage.installing;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> check({bool automatic = false}) async {
    if (_disposed || busy) return;
    stage = ClientUpdateStage.checking;
    error = null;
    _notify();
    try {
      final scope = await api.captureRequestScope(isCurrent: () => !_disposed);
      installed = await bridge.context();
      if (_disposed) return;
      if (installed!.platform == 'web' ||
          installed!.platform == 'linux' ||
          !installed!.supportsInPlaceUpdate &&
              !{'ios', 'macos'}.contains(installed!.platform)) {
        stage = ClientUpdateStage.idle;
        _notify();
        return;
      }
      final result = await scope.run(
        () => api.get(
          '/client-updates/check',
          query: {
            'platform': installed!.platform,
            'architecture': installed!.architecture,
            'currentBuildNumber': installed!.currentBuild,
          },
        ),
      );
      if (_disposed) return;
      checkIntervalSeconds =
          ((result['checkIntervalSeconds'] as num?)?.toInt() ?? 300).clamp(
            60,
            86400,
          );
      final candidate =
          result['updateAvailable'] == true && result['release'] is Map
          ? ClientRelease.fromJson(
              Map<String, dynamic>.from(result['release'] as Map),
            )
          : null;
      release = candidate != null && candidate.matches(installed!)
          ? candidate
          : null;
      hasSuccessfulCheck = true;
      lastCheckedAt = DateTime.now();
      stage = release == null
          ? ClientUpdateStage.idle
          : ClientUpdateStage.available;
    } catch (e) {
      if (_disposed) return;
      if (!automatic) {
        error = e;
        stage = ClientUpdateStage.failed;
      } else {
        stage = release == null
            ? ClientUpdateStage.idle
            : ClientUpdateStage.available;
      }
    }
    _notify();
  }

  Future<void> update() async {
    final candidate = release;
    final context = installed;
    if (_disposed || busy || candidate == null || context == null) return;
    error = null;
    progress = 0;
    stage = ClientUpdateStage.downloading;
    _notify();
    String? packagePath;
    try {
      final scope = await api.captureRequestScope(isCurrent: () => !_disposed);
      if (candidate.installMode == 'store') {
        final uri = candidate.trustedStoreUri;
        if (uri == null ||
            !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw StateError('Store unavailable');
        }
        stage = ClientUpdateStage.installerOpened;
      } else {
        if (!context.supportsInPlaceUpdate ||
            (context.platform == 'windows' &&
                candidate.installMode != 'windows_archive') ||
            (context.platform == 'android' &&
                candidate.installMode != 'android_package') ||
            !{'windows', 'android'}.contains(context.platform)) {
          throw UnsupportedError('Native updater unavailable');
        }
        _download = CancelToken();
        final stream = await scope.run(
          () => api.getPackageStream(
            candidate.packagePath,
            cancelToken: _download!,
          ),
        );
        packagePath = await saveClientPackage(stream, context, candidate, (
          value,
        ) {
          progress = value;
          _notify();
        }, () => !_disposed && scope.isCurrent);
        await scope.verify();
        if (_disposed) return;
        stage = ClientUpdateStage.installing;
        _notify();
        await bridge.install(packagePath, candidate);
        if (_disposed) return;
        stage = ClientUpdateStage.installerOpened;
      }
    } catch (e) {
      if (packagePath != null) {
        try {
          await removeClientPackage(packagePath);
        } catch (_) {
          /* Keep the installation failure visible. */
        }
      }
      if (_disposed) return;
      error = e;
      stage = ClientUpdateStage.failed;
    } finally {
      _download = null;
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _download?.cancel('Client update owner changed');
    for (final listener in _ownerDisposedListeners) {
      scheduleMicrotask(listener);
    }
    _ownerDisposedListeners.clear();
    super.dispose();
  }
}
