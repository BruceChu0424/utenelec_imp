import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/server_config.dart';
import 'client_package_download.dart';
import 'client_release.dart';
import 'client_update_bridge.dart';

class StagedClientUpdate {
  const StagedClientUpdate({
    required this.endpoint,
    required this.path,
    required this.release,
    required this.context,
  });

  final String endpoint;
  final String path;
  final ClientRelease release;
  final ClientInstallContext context;
}

/// Verified local packages survive login changes, but never endpoint changes.
class ClientStagedUpdateStore extends ChangeNotifier {
  ClientStagedUpdateStore(this.endpoint);
  final String endpoint;
  StagedClientUpdate? update;
  final _failedAutomaticReleases = <String>{};
  bool applying = false;
  bool installerOpened = false;
  Object? error;
  bool _disposed = false;

  void reconcile(ClientRelease? available) {
    final staged = update;
    if (staged == null) return;
    final original = staged.release;
    if (available != null &&
        available.id == original.id &&
        available.version == original.version &&
        available.buildNumber == original.buildNumber &&
        available.sizeBytes == original.sizeBytes &&
        available.sha256.toLowerCase() == original.sha256.toLowerCase() &&
        available.platform == original.platform &&
        available.architecture == original.architecture &&
        available.runtimeFamily == original.runtimeFamily &&
        available.installMode == original.installMode &&
        available.state == 'PUBLISHED') {
      return;
    }
    update = null;
    if (!applying && !installerOpened) {
      unawaited(removeClientPackage(staged.path).catchError((Object _) {}));
    }
    notifyListeners();
  }

  bool mayApplyAutomatically(StagedClientUpdate entry) =>
      !_disposed &&
      !applying &&
      !installerOpened &&
      identical(update, entry) &&
      entry.endpoint == endpoint &&
      !_failedAutomaticReleases.contains(entry.release.id) &&
      entry.context.platform == 'windows' &&
      entry.context.supportsInPlaceUpdate &&
      !entry.context.requiresSystemConfirmation &&
      !entry.context.lastUpdateFailed &&
      entry.release.installMode == 'windows_archive';

  void stage(StagedClientUpdate entry) {
    if (_disposed || entry.endpoint != endpoint) {
      unawaited(removeClientPackage(entry.path));
      return;
    }
    final previous = update;
    update = entry;
    installerOpened = false;
    error = null;
    if (previous != null && previous.path != entry.path) {
      unawaited(removeClientPackage(previous.path).catchError((Object _) {}));
    }
    notifyListeners();
  }

  Future<bool> apply({
    required ClientUpdateBridge bridge,
    required bool Function() isSafe,
    Future<void> Function()? verifySession,
    bool automatic = false,
  }) async {
    final entry = update;
    if (_disposed ||
        applying ||
        installerOpened ||
        entry == null ||
        entry.endpoint != endpoint ||
        automatic && !mayApplyAutomatically(entry) ||
        !isSafe()) {
      return false;
    }
    applying = true;
    error = null;
    notifyListeners();
    try {
      final installed = await bridge.context();
      if (_disposed ||
          !identical(update, entry) ||
          !entry.release.matches(installed)) {
        return false;
      }
      if (automatic &&
          (installed.platform != 'windows' ||
              !installed.supportsInPlaceUpdate ||
              installed.requiresSystemConfirmation ||
              installed.lastUpdateFailed)) {
        return false;
      }
      await verifyClientPackage(entry.path, entry.release);
      await verifySession?.call();
      if (_disposed || !identical(update, entry) || !isSafe()) return false;
      await bridge.install(entry.path, entry.release);
      installerOpened = true;
      return !_disposed;
    } catch (failure) {
      error = failure;
      if (automatic) _failedAutomaticReleases.add(entry.release.id);
      rethrow;
    } finally {
      applying = false;
      if ((_disposed || !identical(update, entry)) && !installerOpened) {
        unawaited(removeClientPackage(entry.path).catchError((Object _) {}));
      }
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final entry = update;
    update = null;
    if (entry != null && !applying && !installerOpened) {
      unawaited(removeClientPackage(entry.path).catchError((Object _) {}));
    }
    super.dispose();
  }
}

final clientStagedUpdateStoreProvider = Provider<ClientStagedUpdateStore>((
  ref,
) {
  final store = ClientStagedUpdateStore(ref.watch(apiBaseUrlProvider));
  ref.onDispose(store.dispose);
  return store;
});
