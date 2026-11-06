import 'dart:async';

/// The immutable query/reader fence retires its HTTP reads. This cancellation
/// intent never applies to a business command or retries an uncertain write.
abstract final class PagedReadIntent {
  static final _readCurrentKey = Object();
  static final _activityKey = Object();
  static final _bootstrapKey = Object();

  static bool Function()? get currentRead =>
      Zone.current[_readCurrentKey] as bool Function()?;

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
