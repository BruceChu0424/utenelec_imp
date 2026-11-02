import 'dart:async';

import 'package:flutter/foundation.dart';

/// A synchronous, side-effect-free summary. No editor values cross this bridge.
class WebUpdateSafetyState {
  const WebUpdateSafetyState({
    this.dirty = false,
    this.busy = false,
    this.blocked = false,
    this.serverReloadOverride,
  });

  final bool dirty;
  final bool busy;
  final bool blocked;
  final bool? serverReloadOverride;

  bool get isSafe => !dirty && !busy && !blocked;

  bool get safeToReload => isSafe;

  /// A server release may restore a durable draft instead of waiting for the
  /// user to submit it. Pending/ambiguous commands still own their own fence.
  bool get serverReloadSafe => serverReloadOverride ?? isSafe;
}

class WebUpdateSafetySnapshot extends WebUpdateSafetyState {
  const WebUpdateSafetySnapshot({
    required this.ready,
    super.dirty,
    super.busy,
    super.blocked,
    super.serverReloadOverride,
  });

  final bool ready;

  @override
  bool get isSafe => ready && super.isSafe;

  @override
  bool get serverReloadSafe => ready && super.serverReloadSafe;

  Map<String, Object> toJson({DateTime? now}) => {
    'schemaVersion': 1,
    'ready': ready,
    'dirty': dirty,
    'busy': busy,
    'blocked': blocked,
    'serverReloadSafe': serverReloadSafe,
    'updatedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
  };
}

/// Editors, pending commands and visible dialogs own independent blockers.
/// Reading this registry never saves a draft or invokes a leave confirmation.
class WebUpdateSafetyRegistry extends ChangeNotifier {
  final _probes = <Object, WebUpdateSafetyState Function()>{};
  final _serverReloadCheckpoints = <Object, Future<void> Function()>{};
  bool _ready = false;
  bool _notificationScheduled = false;
  bool _disposed = false;
  WebUpdateSafetySnapshot? _lastNotified;

  bool get isSafe => snapshot.isSafe;
  bool get safeToReload => snapshot.safeToReload;

  void register(Object owner, WebUpdateSafetyState Function() probe) {
    if (_probes[owner] == probe) return;
    _probes[owner] = probe;
    changed();
  }

  void unregister(Object owner) {
    if (_probes.remove(owner) != null) changed();
    _serverReloadCheckpoints.remove(owner);
  }

  void registerServerReloadCheckpoint(
    Object owner,
    Future<void> Function() checkpoint,
  ) => _serverReloadCheckpoints[owner] = checkpoint;

  Future<bool> prepareServerReload() async {
    try {
      // Await actual storage commits, not pagehide's fire-and-forget writes.
      for (final checkpoint in List.of(_serverReloadCheckpoints.values)) {
        await checkpoint();
      }
      return snapshot.serverReloadSafe;
    } catch (_) {
      return false;
    }
  }

  void setReady(bool ready) {
    if (_ready == ready) return;
    _ready = ready;
    changed();
  }

  void changed() {
    if (_notificationScheduled || _disposed) return;
    _notificationScheduled = true;
    scheduleMicrotask(() {
      _notificationScheduled = false;
      if (_disposed) return;
      final next = snapshot;
      final previous = _lastNotified;
      if (previous != null &&
          previous.ready == next.ready &&
          previous.dirty == next.dirty &&
          previous.busy == next.busy &&
          previous.blocked == next.blocked &&
          previous.serverReloadSafe == next.serverReloadSafe) {
        return;
      }
      _lastNotified = next;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _probes.clear();
    _serverReloadCheckpoints.clear();
    super.dispose();
  }

  WebUpdateSafetySnapshot get snapshot {
    var dirty = false, busy = false, blocked = false;
    var serverReloadSafe = true;
    for (final probe in List.of(_probes.values)) {
      try {
        final state = probe();
        dirty |= state.dirty;
        busy |= state.busy;
        blocked |= state.blocked;
        serverReloadSafe &= state.serverReloadSafe && !state.busy;
      } catch (_) {
        // An unavailable editor is unknown, never evidence for a clean page.
        blocked = true;
        serverReloadSafe = false;
      }
    }
    return WebUpdateSafetySnapshot(
      ready: _ready,
      dirty: dirty,
      busy: busy,
      blocked: blocked,
      serverReloadOverride: serverReloadSafe,
    );
  }
}

final webUpdateSafety = WebUpdateSafetyRegistry();
