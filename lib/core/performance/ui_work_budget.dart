import 'dart:async';

/// Optional local profiling hook. Production does not install a listener and
/// no values, row identities or response contents are sent to it.
void Function(String label, Duration elapsed)? debugUiWorkSliceObserver;

/// A presentation job was superseded or its owner left the current scope.
///
/// This is not a transport cancellation or a business-command outcome.
class UiWorkCancelled implements Exception {
  const UiWorkCancelled();
}

/// Bounds synchronous presentation work between real event-loop turns.
///
/// `async`, a microtask, and painting a loading indicator once do not keep a
/// large CPU-bound loop responsive. Checkpoint loops before publishing their
/// complete result. No partial projection is published by this helper.
///
/// A timer turn also works in a hidden browser tab, unlike waiting exclusively
/// for `endOfFrame`. It gives the UI a chance to process frames and input; it
/// does not move arbitrary callbacks to another thread or isolate.
class UiWorkBudget {
  UiWorkBudget({
    this.slice = const Duration(milliseconds: 4),
    this.maxItems = 256,
    this.isCurrent,
    this.debugLabel = 'presentation',
  }) : assert(slice > Duration.zero),
       assert(maxItems > 0);

  final Duration slice;
  final int maxItems;
  final bool Function()? isCurrent;
  final String debugLabel;
  final Stopwatch _clock = Stopwatch()..start();
  int _items = 0;

  void ensureCurrent() {
    if (isCurrent?.call() == false) throw const UiWorkCancelled();
  }

  Future<void> checkpoint([int items = 1]) async {
    ensureCurrent();
    _items += items;
    if (_items < maxItems && _clock.elapsed < slice) return;
    debugUiWorkSliceObserver?.call(debugLabel, _clock.elapsed);
    await Future<void>.delayed(Duration.zero);
    ensureCurrent();
    _items = 0;
    _clock.reset();
  }
}

/// Converts a bounded snapshot without monopolising the UI event loop.
///
/// The result preserves input order and is only returned after all items have
/// been converted. Callers must still fence publication against identity and
/// request changes, and bound their retained data independently.
Future<List<R>> mapInUiSlices<T, R>(
  Iterable<T> values,
  R Function(T value) convert, {
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget();
  work.ensureCurrent();
  // Freeze membership before yielding; owners still fence mutable value data.
  final snapshot = List<T>.of(values, growable: false);
  final result = <R>[];
  for (final value in snapshot) {
    result.add(convert(value));
    await work.checkpoint();
  }
  work.ensureCurrent();
  return result;
}
