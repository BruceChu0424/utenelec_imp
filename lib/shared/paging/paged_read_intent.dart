import 'dart:async';

import '../models/paged_result.dart';

/// The immutable query/reader fence retires its HTTP reads. This cancellation
/// intent never applies to a business command or retries an uncertain write.
abstract final class PagedReadIntent {
  static final _readCurrentKey = Object();
  static final _activityKey = Object();
  static final _bootstrapKey = Object();
  static final _progressiveKey = Object();

  static bool Function()? get currentRead =>
      Zone.current[_readCurrentKey] as bool Function()?;

  /// The progressive publication slot of the complete read running in this
  /// zone, if its view opted in. Only the reader whose rows are the view's rows
  /// may claim it; auxiliary complete reads in the same zone never publish.
  static PagedReadProgressiveSink? get currentProgressive =>
      Zone.current[_progressiveKey] as PagedReadProgressiveSink?;

  static R progressiveRead<R>(
    PagedReadProgressiveSink sink,
    R Function() action,
  ) => runZoned(action, zoneValues: {_progressiveKey: sink});

  static List<PagedReadActivityFence> get _activities =>
      Zone.current[_activityKey] as List<PagedReadActivityFence>? ?? const [];

  /// Presentation retirement is separate from logical ownership: a received
  /// access rejection still belongs to its current account/query/request.
  static bool Function()? get currentActivity {
    final activities = _activities;
    return activities.isEmpty
        ? null
        : () => activities.every((activity) => activity.isCurrent());
  }

  static bool get allowsInactiveBootstrap =>
      _activities.isNotEmpty &&
      _activities.every(
        (activity) => activity.isCurrent() || activity.allowInactiveBootstrap,
      );

  static bool Function()? get currentTransportActivity {
    final activities = _activities;
    final bootstrap = Zone.current[_bootstrapKey] == true;
    return activities.isEmpty
        ? null
        : () => activities.every(
            (activity) =>
                activity.isCurrent() ||
                bootstrap && activity.allowInactiveBootstrap,
          );
  }

  /// A shared producer has its own auth/write/query lifetime. It must not borrow
  /// the first foreground consumer's request or presentation retirement.
  static R ownedRead<R>(bool Function() owner, R Function() action) => runZoned(
    action,
    zoneValues: {
      _readCurrentKey: owner,
      _activityKey: const <PagedReadActivityFence>[],
      _bootstrapKey: false,
    },
  );

  static R scopedRead<R>(
    bool Function() isCurrent,
    R Function() action, {
    PagedReadActivityFence? activity,
    bool? bootstrap,
  }) {
    final parent = currentRead;
    final activities = _activities;
    return runZoned(
      action,
      zoneValues: {
        _readCurrentKey: () => (parent?.call() ?? true) && isCurrent(),
        _activityKey: activity == null
            ? activities
            : List<PagedReadActivityFence>.unmodifiable([
                ...activities,
                activity,
              ]),
        _bootstrapKey: bootstrap ?? Zone.current[_bootstrapKey] == true,
      },
    );
  }
}

class PagedReadActivityFence {
  const PagedReadActivityFence({
    required this.isCurrent,
    this.allowInactiveBootstrap = false,
  });
  final bool Function() isCurrent;
  final bool allowInactiveBootstrap;
}

/// Progressive publication slot of one complete read (2026-11-08): claimed
/// once, then every validated batch may publish the accumulated rows while the
/// read continues. The owner's publish callback re-checks its request/owner
/// fence and binds the rows as pending; totals, exports and batch actions still
/// wait for the complete result, and a failed read retires the progressive
/// rows as a whole.
class PagedReadProgressiveSink {
  PagedReadProgressiveSink(this._publish);
  final void Function(PagedResult<Object?> partial) _publish;
  bool _claimed = false;

  /// The first complete reader of the view's rows claims the slot; nested or
  /// auxiliary complete reads in the same zone get `false` and never publish.
  bool claim() {
    if (_claimed) return false;
    _claimed = true;
    return true;
  }

  void publish(PagedResult<Object?> partial) => _publish(partial);
}
