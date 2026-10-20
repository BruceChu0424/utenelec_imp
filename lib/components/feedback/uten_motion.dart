import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../shared/providers/performance_provider.dart';

ProviderContainer? _containerOf(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false);
  } on StateError {
    // Shared layout primitives also work outside the application's provider
    // scope (for example in a standalone dialog preview).
    return null;
  }
}

Duration _resolve(
  BuildContext context,
  Duration duration,
  PerformanceTier? tier,
) =>
    tier?.isLite == true ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled
    ? Duration.zero
    : duration;

/// Resolves one route's motion before it is pushed.
Duration utenMotionDurationOf(BuildContext context, Duration duration) =>
    _resolve(
      context,
      duration,
      _containerOf(context)?.read(performanceProvider),
    );

/// Resolves interaction motion and reacts to accessibility, ticker and
/// performance changes without requiring a provider scope in standalone uses.
class UtenMotion extends StatelessWidget {
  const UtenMotion({super.key, required this.duration, required this.builder});

  final Duration duration;
  final Widget Function(BuildContext context, Duration duration) builder;

  @override
  Widget build(BuildContext context) {
    if (_containerOf(context) == null) {
      return builder(context, _resolve(context, duration, null));
    }
    return Consumer(
      builder: (context, ref, _) => builder(
        context,
        _resolve(context, duration, ref.watch(performanceProvider)),
      ),
    );
  }
}
