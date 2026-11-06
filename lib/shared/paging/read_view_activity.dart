import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/network/api_exception.dart';
import '../../core/performance/ui_work_budget.dart';
import '../../core/router/page_search_lifecycle.dart';
import '../../core/router/route_transition_tracker.dart';
import 'paged_read_intent.dart';

/// Expected retirement of a read is quiet; access rejection and malformed
/// server data are still handled by the original owner/error contract.
bool isRetiredViewRead(Object error) =>
    error is UiWorkCancelled ||
    error is ApiException && error.code == 'REQUEST_STALE';

/// Foreground read demand, independent of accepted authorization/data ownership.
/// A departure retires old tickets monotonically, including a quick A-B-A.
/// Multiple consumers share demand; one hidden view cannot cancel another.
class ReadViewActivity {
  ReadViewActivity({this.onResume});

  final FutureOr<void> Function()? onResume;
  final _views = <BuildContext, _ReadViewBinding>{};
  final _latest = <Object, _ReadActivityAdmission>{};
  final _foregroundWaiters = <_ForegroundReadWaiter>{};
  bool _everBound = false;
  bool _active = true; // A pure no-view/background reader remains legitimate.
  bool _foregroundActive = true;
  bool _disposed = false;
  static const _defaultSlot = 'read';
  bool get _needsResume =>
      _latest.values.any((read) => read.resumeNeeded && read.logicalCurrent);
  bool _resumeScheduled = false;
  int _epoch = 0;
  int _pending = 0;
  int _backgroundDemand = 0;
  Zone _viewZone = Zone.root;

  /// Bind in build/didChangeDependencies, never initState. [isCurrent] is a
  /// persistent view/query relevance check, not a single request's generation.
  void bindView(BuildContext context, {bool Function()? isCurrent}) {
    if (_disposed || !context.mounted) return;
    _viewZone = Zone.current;
    _everBound = true;
    final binding = _views[context];
    if (binding == null) {
      _views[context] = _ReadViewBinding(context, isCurrent, _changed);
    } else {
      binding.update(isCurrent);
    }
    _changed();
  }

  bool _synchronize() {
    if (_disposed) return false;
    final removed = _views.entries
        .where((entry) => !entry.key.mounted)
        .map((entry) => entry.key)
        .toList();
    for (final context in removed) {
      _views.remove(context)?.dispose();
    }
    final foregroundActive =
        !_everBound || _views.values.any((view) => view.active);
    final active = _backgroundDemand > 0 || foregroundActive;
    if (_foregroundActive && !foregroundActive) {
      for (final read in _latest.values) {
        read.resumeNeeded = true;
      }
    }
    if (_active && !active) _epoch++;
    _foregroundActive = foregroundActive;
    _active = active;
    for (final waiter in _foregroundWaiters.toList(growable: false)) {
      final current = waiter.isCurrent;
      if (!current || foregroundActive) {
        _foregroundWaiters.remove(waiter);
        waiter.result.complete(current);
      }
    }
    return active;
  }

  void _changed() {
    _synchronize();
    _scheduleResume();
  }

  /// A complete-set/export consumer may deliberately outlive a hidden view.
  /// Acquire before awaiting that read; releasing demand never revives a ticket
  /// retired before acquisition. Logical/auth/query fences remain mandatory.
  VoidCallback retainBackground() {
    if (_disposed) return () {};
    _backgroundDemand++;
    _changed();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _backgroundDemand--;
      _changed();
    };
  }

  /// An explicit navigation workflow may need its return read to finish before
  /// releasing its busy state. Wait for the presentation, then let the caller
  /// capture a NEW query/read ticket. This never revives a retired read or makes
  /// a hidden view background demand, and does not wrap/replay any command.
  Future<bool> waitForForeground(bool Function() logicalCurrent) async {
    final owner = _ForegroundReadWaiter(logicalCurrent);
    while (!_disposed && owner.isCurrent) {
      _synchronize();
      if (_foregroundActive) return true;
      final waiter = _ForegroundReadWaiter(logicalCurrent);
      _foregroundWaiters.add(waiter);
      if (!await waiter.result.future) return false;
      // A short active pulse may have ended before this continuation. Remain
      // queued for presentation instead of reviving an inactive read ticket.
    }
    return false;
  }

  /// May start in initState before view binding. An initially unbound read may
  /// finish its first bounded bootstrap/HWM transport after an inactive bind.
  /// A view already known to be inactive admits no foreground transport.
  Future<T> runRead<T>(
    bool Function() logicalCurrent,
    Future<T> Function() read, {
    Object slot = _defaultSlot,
  }) async {
    final activeAtAdmission = _synchronize();
    final inactiveAdmission = _everBound && !activeAtAdmission;
    final allowBootstrap = !_everBound;
    final epoch = _epoch;
    final admission = _ReadActivityAdmission(
      logicalCurrent,
      resumeNeeded: !_foregroundActive,
    );
    _latest[slot] = admission;
    _pending++;
    bool current() {
      _synchronize();
      return !_disposed && !inactiveAdmission && epoch == _epoch && _active;
    }

    try {
      if (inactiveAdmission) throw const UiWorkCancelled();
      final result = await PagedReadIntent.scopedRead(
        logicalCurrent,
        read,
        activity: PagedReadActivityFence(
          isCurrent: current,
          allowInactiveBootstrap: allowBootstrap,
        ),
      );
      if (!logicalCurrent() || !current()) throw const UiWorkCancelled();
      return result;
    } finally {
      // A newer query/identity/request pipeline already owns its own reload.
      // Do not race that pending intent (for example input debounce) with the
      // old visit's fallback refresh.
      try {
        if (identical(_latest[slot], admission) && !logicalCurrent()) {
          admission.resumeNeeded = false;
        }
      } catch (_) {
        if (identical(_latest[slot], admission)) {
          admission.resumeNeeded = false;
        }
      }
      _pending--;
      _scheduleResume();
    }
  }

  void _scheduleResume() {
    if (_disposed ||
        !_active ||
        !_foregroundActive ||
        !_needsResume ||
        _pending != 0 ||
        _resumeScheduled ||
        onResume == null) {
      return;
    }
    _resumeScheduled = true;
    _viewZone.run(
      () => whenRouteTransitionsSettled(() {
        // Existing PageResume/explicit pop-return callbacks own the first fresh
        // attempt. Their runRead admission clears this fallback demand.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _resumeScheduled = false;
          if (!_synchronize() ||
              !_foregroundActive ||
              _disposed ||
              !_needsResume ||
              _pending != 0) {
            return;
          }
          for (final read in _latest.values) {
            read.resumeNeeded = false;
          }
          Future<void>.sync(onResume!).then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              // The owner keeps its existing error UI. No automatic retry loop.
            },
          );
        });
        SchedulerBinding.instance.ensureVisualUpdate();
      }),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    for (final view in _views.values) {
      view.dispose();
    }
    _views.clear();
    _latest.clear();
    for (final waiter in _foregroundWaiters) {
      waiter.result.complete(false);
    }
    _foregroundWaiters.clear();
  }
}

class _ForegroundReadWaiter {
  _ForegroundReadWaiter(this._current);
  final bool Function() _current;
  final result = Completer<bool>();
  bool get isCurrent {
    try {
      return _current();
    } catch (_) {
      return false;
    }
  }
}

class _ReadActivityAdmission {
  _ReadActivityAdmission(this._current, {required this.resumeNeeded});
  final bool Function() _current;
  bool resumeNeeded;
  bool get logicalCurrent {
    try {
      return _current();
    } catch (_) {
      return false;
    }
  }
}

class _ReadViewBinding {
  _ReadViewBinding(this.context, this.relevant, this.changed) {
    _ticker = TickerMode.getValuesNotifier(context)..addListener(changed);
    _navigation = PageSearchLifecycle(onLeave: changed, onReturn: changed)
      ..attach(context, fallbackToActivePage: true);
  }
  final BuildContext context;
  final VoidCallback changed;
  bool Function()? relevant;
  late ValueListenable<TickerModeData> _ticker;
  late final PageSearchLifecycle _navigation;

  bool get active {
    if (!context.mounted) return false;
    try {
      return (relevant?.call() ?? true) &&
          _ticker.value.enabled &&
          _navigation.isActive;
    } catch (_) {
      return false;
    }
  }

  void update(bool Function()? value) {
    relevant = value;
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker.removeListener(changed);
      _ticker = ticker..addListener(changed);
    }
    _navigation.attach(context, fallbackToActivePage: true);
  }

  void dispose() {
    _ticker.removeListener(changed);
    _navigation.dispose();
  }
}

/// Direct State owners compose this only around reads, leaving shared command
/// predicates/unsaved/unknown-submission guards unchanged.
mixin ReadViewActivityMixin<W extends StatefulWidget> on State<W> {
  late final readViewActivity = ReadViewActivity(onResume: onReadViewResumed);

  FutureOr<void> onReadViewResumed() {}

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    readViewActivity.bindView(context);
  }

  @override
  void dispose() {
    readViewActivity.dispose();
    super.dispose();
  }
}
