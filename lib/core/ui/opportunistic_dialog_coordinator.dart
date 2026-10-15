import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Existing business/security reminders have priority over optional suggestions.
/// This coordinates ownership only; it never pops an arbitrary navigator route.
final opportunisticDialogCoordinatorProvider =
    Provider<OpportunisticDialogCoordinator>((ref) {
      final coordinator = OpportunisticDialogCoordinator();
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

class OpportunisticDialogCoordinator extends ChangeNotifier {
  final _blockers = <Object>{};
  DialogOpportunity? _opportunity;
  bool _disposed = false;
  bool get blocked => _blockers.isNotEmpty;

  DialogPriorityReservation prioritize() {
    final token = Object();
    _blockers.add(token);
    _opportunity?.interrupt();
    notifyListeners();
    return DialogPriorityReservation._(() {
      if (_disposed) return;
      if (_blockers.remove(token)) notifyListeners();
    });
  }

  DialogOpportunity? tryAcquire() {
    if (_disposed || blocked || _opportunity != null) return null;
    late final DialogOpportunity opportunity;
    opportunity = DialogOpportunity._(() {
      if (identical(_opportunity, opportunity)) _opportunity = null;
    });
    _opportunity = opportunity;
    return opportunity;
  }

  @override
  void dispose() {
    _disposed = true;
    _opportunity?.interrupt();
    _blockers.clear();
    super.dispose();
  }
}

class DialogPriorityReservation {
  DialogPriorityReservation._(this._release);
  VoidCallback? _release;
  void release() {
    final callback = _release;
    _release = null;
    callback?.call();
  }
}

class DialogOpportunity extends ChangeNotifier {
  DialogOpportunity._(this._release);
  VoidCallback? _release;
  bool interrupted = false;
  bool _disposed = false;
  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    // A priority check can win after push() but before the optional route's
    // widget has installed its listener. Replay cancellation to that exact route.
    if (interrupted) {
      scheduleMicrotask(() {
        if (!_disposed) listener();
      });
    }
  }

  void interrupt() {
    if (_disposed || interrupted) return;
    interrupted = true;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final callback = _release;
    _release = null;
    callback?.call();
    super.dispose();
  }
}
