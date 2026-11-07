import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show FlutterError;

/// Response streams/codecs can use real browser tasks even with a fake adapter.
/// Advance one actual I/O event turn; this adds no elapsed-time allowance.
Future<void> _pumpIoTurn(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
}

/// Advances one caller-selected fake frame and one actual I/O event turn.
/// Fixed-frame fixtures retain their own frame count and duration.
Future<void> pumpWithIo(
  WidgetTester tester, [
  Duration duration = Duration.zero,
]) async {
  await _pumpIoTurn(tester);
  await tester.pump(duration);
}

/// The same frame step and fake-clock deadline as WidgetTester.pumpAndSettle,
/// while allowing a real response stream to complete between widget frames.
Future<int> pumpAndSettleWithIo(
  WidgetTester tester, {
  Duration duration = const Duration(milliseconds: 100),
  Duration timeout = const Duration(minutes: 10),
}) {
  assert(duration > Duration.zero);
  assert(timeout > Duration.zero);
  return TestAsyncUtils.guard<int>(() async {
    final end = tester.binding.clock.fromNowBy(timeout);
    var count = 0;
    do {
      if (tester.binding.clock.now().isAfter(end)) {
        throw FlutterError('pumpAndSettle timed out');
      }
      await pumpWithIo(tester, duration);
      count++;
    } while (tester.binding.hasScheduledFrame);
    return count;
  });
}

/// Waits for a concrete UI result while an intentionally held request may keep
/// a loading animation alive. Completing that request remains the test's job.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  Duration timeout = const Duration(seconds: 2),
  bool realIo = false,
}) async {
  final deadline = tester.binding.clock.fromNowBy(timeout);
  do {
    if (realIo) {
      await pumpWithIo(tester, const Duration(milliseconds: 16));
    } else {
      await tester.pump(const Duration(milliseconds: 16));
    }
    if (ready()) return;
  } while (tester.binding.clock.now().isBefore(deadline));
  throw TestFailure(reason);
}

/// Advances the fake widget clock while responsive work yields via timers.
/// Errors retain their original stack; a timeout never silently accepts a job.
Future<void> pumpUntilCompletes(
  WidgetTester tester,
  Future<void> operation, {
  required String reason,
  Duration timeout = const Duration(seconds: 5),
}) async {
  var done = false;
  Object? failure;
  StackTrace? trace;
  final completed = operation.then<void>(
    (_) => done = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      trace = stack;
      done = true;
    },
  );
  await pumpUntil(tester, () => done, reason: reason, timeout: timeout);
  await completed;
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
}
