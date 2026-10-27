import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sensitive_read_boundary_provider.dart';
import '../providers/session_provider.dart';
import 'session_epoch_provider.dart';

/// Lifetime of one operator-owned account action. This grants no permission;
/// callers still enforce their action and target policy. Once lost, ownership
/// cannot revive when an account, endpoint, or target returns to its old value.
class AccountActionOwner {
  AccountActionOwner(
    this._ref, {
    bool Function()? isCurrent,
    Listenable? targetChanges,
    this._onInvalidated,
  }) : boundary = _ref.read(sensitiveReadBoundaryProvider),
       _targetIsCurrent = isCurrent {
    _boundaryChanges = _ref.listenManual(
      sensitiveReadBoundaryProvider,
      (_, _) => _changed(),
    );
    // Direct notifications retain same-frame logout/login ABA protection;
    // a computed boundary alone can coalesce the intermediate signed-out state.
    _sessionChanges = _ref.listenManual(sessionProvider, (_, _) => _changed());
    _epochChanges = _ref.listenManual(
      sessionEpochProvider,
      (_, _) => _changed(),
    );
    watchTargetChanges(targetChanges);
  }

  final WidgetRef _ref;
  final SensitiveReadBoundary boundary;
  final bool Function()? _targetIsCurrent;
  final VoidCallback? _onInvalidated;
  late final ProviderSubscription<SensitiveReadBoundary> _boundaryChanges;
  late final ProviderSubscription<SessionState> _sessionChanges;
  late final ProviderSubscription<int> _epochChanges;
  Listenable? _targetChanges;
  bool _invalidated = false;
  bool _notified = false;
  bool _disposed = false;

  bool get isCurrent {
    if (_invalidated || _disposed) return false;
    try {
      if (boundary == _ref.read(sensitiveReadBoundaryProvider) &&
          (_targetIsCurrent?.call() ?? true)) {
        return true;
      }
    } catch (_) {
      // A caller may already be deactivated while its route is being removed.
    }
    _invalidated = true;
    return false;
  }

  void _changed() {
    if (!isCurrent && !_notified && !_disposed) {
      _notified = true;
      _onInvalidated?.call();
    }
  }

  void watchTargetChanges(Listenable? changes) {
    if (identical(changes, _targetChanges)) return;
    _targetChanges?.removeListener(_targetChanged);
    _targetChanges = changes;
    _targetChanges?.addListener(_targetChanged);
  }

  void _targetChanged() {
    _invalidated = true;
    _changed();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _targetChanges?.removeListener(_targetChanged);
    _boundaryChanges.close();
    _sessionChanges.close();
    _epochChanges.close();
  }
}
