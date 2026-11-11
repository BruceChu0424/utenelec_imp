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
  late final _notifications = _DeferredDialogNotification(notifyListeners);
  bool get blocked => _blockers.isNotEmpty;

  DialogPriorityReservation prioritize() {
    final token = Object();
    _blockers.add(token);
    _opportunity?.interrupt();
    _notifications.schedule();
    return DialogPriorityReservation._(() {
      if (_disposed) return;
      if (_blockers.remove(token)) _notifications.schedule();
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
    _notifications.dispose();
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
  late final _notifications = _DeferredDialogNotification(notifyListeners);
  final _registrations = <VoidCallback, List<Object>>{};
  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    final registration = Object();
    (_registrations[listener] ??= []).add(registration);
    // A priority check can win after push() but before the optional route's
    // widget has installed its listener. Replay cancellation to that exact route.
    if (interrupted && !_notifications.queued) {
      scheduleMicrotask(() {
        if (!_disposed &&
            (_registrations[listener]?.contains(registration) ?? false)) {
          listener();
        }
      });
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    final registrations = _registrations[listener];
    if (registrations == null) return;
    registrations.removeAt(0);
    if (registrations.isEmpty) _registrations.remove(listener);
  }

  void interrupt() {
    if (_disposed || interrupted) return;
    interrupted = true;
    _notifications.schedule();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _notifications.dispose();
    _registrations.clear();
    final callback = _release;
    _release = null;
    callback?.call();
    super.dispose();
  }
}

/// Priority ownership changes immediately. Its UI effects run after the current
/// synchronous tree update/layout has completed, before the next event/frame.
/// This also covers callers that reserve/release from initState or dispose.
class _DeferredDialogNotification {
  _DeferredDialogNotification(this._notify);
  final VoidCallback _notify;
  bool queued = false;
  bool _disposed = false;

  void schedule() {
    if (_disposed || queued) return;
    queued = true;
    scheduleMicrotask(() {
      queued = false;
      if (!_disposed) _notify();
    });
  }

  void dispose() => _disposed = true;
}
