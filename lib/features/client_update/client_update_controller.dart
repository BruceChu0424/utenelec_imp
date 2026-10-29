import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../core/web_update/web_update_safety.dart';
import '../../shared/providers/session_provider.dart';
import 'client_package_download.dart';
import 'client_release.dart';
import 'client_update_bridge.dart';
import 'client_staged_update.dart';

final clientUpdateBridgeProvider = Provider((ref) => ClientUpdateBridge());

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
    bridge: ref.watch(clientUpdateBridgeProvider),
    stagedUpdates: ref.watch(clientStagedUpdateStoreProvider),
    canInstall: () => webUpdateSafety.safeToReload,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

class ClientUpdateController extends ChangeNotifier {
  ClientUpdateController({
    required this.api,
    required this.bridge,
    ClientStagedUpdateStore? stagedUpdates,
    bool Function()? canInstall,
  }) : stagedUpdates = stagedUpdates ?? ClientStagedUpdateStore(''),
       _canInstall = canInstall ?? (() => true);
  final ApiClient api;
  final ClientUpdateBridge bridge;
  final ClientStagedUpdateStore stagedUpdates;
  final bool Function() _canInstall;
  bool waitingForSafeInstall = false;
  bool get hasStagedUpdate =>
      stagedUpdates.update?.release.id == release?.id && release != null;
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
      stagedUpdates.reconcile(release);
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
    if (candidate.installMode != 'store') {
      await prepareUpdate();
      if (!_disposed && hasStagedUpdate) await installPrepared();
      return;
    }
    try {
      final scope = await api.captureRequestScope(isCurrent: () => !_disposed);
      await scope.verify();
      if (!_canInstall()) {
        waitingForSafeInstall = true;
        _notify();
        return;
      }
      final uri = candidate.trustedStoreUri;
      if (uri == null ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Store unavailable');
      }
      stage = ClientUpdateStage.installerOpened;
    } catch (failure) {
      if (_disposed) return;
      error = failure;
      stage = ClientUpdateStage.failed;
    }
    _notify();
  }

  Future<void> prepareUpdate() async {
    final candidate = release;
    final context = installed;
    if (_disposed ||
        busy ||
        candidate == null ||
        context == null ||
        candidate.installMode == 'store' ||
        hasStagedUpdate) {
      return;
    }
    error = null;
    progress = 0;
    stage = ClientUpdateStage.downloading;
    _notify();
    String? packagePath;
    try {
      final scope = await api.captureRequestScope(isCurrent: () => !_disposed);
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
      stagedUpdates.stage(
        StagedClientUpdate(
          endpoint: stagedUpdates.endpoint,
          path: packagePath,
          release: candidate,
          context: context,
        ),
      );
      packagePath = null;
      stage = ClientUpdateStage.available;
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

  Future<bool> installPrepared({
    bool automatic = false,
    bool Function()? additionalSafety,
  }) async {
    if (_disposed || busy || !hasStagedUpdate) return false;
    bool safe() =>
        !_disposed && _canInstall() && (additionalSafety?.call() ?? true);
    if (!safe()) {
      waitingForSafeInstall = true;
      _notify();
      return false;
    }
    try {
      final scope = await api.captureRequestScope(isCurrent: () => !_disposed);
      stage = ClientUpdateStage.installing;
      waitingForSafeInstall = false;
      _notify();
      final applied = await stagedUpdates.apply(
        bridge: bridge,
        isSafe: safe,
        verifySession: scope.verify,
        automatic: automatic,
      );
      if (_disposed) return false;
      stage = applied
          ? ClientUpdateStage.installerOpened
          : ClientUpdateStage.available;
      waitingForSafeInstall = !applied;
      _notify();
      return applied;
    } catch (failure) {
      if (!_disposed) {
        error = failure;
        stage = ClientUpdateStage.failed;
        _notify();
      }
      return false;
    }
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
