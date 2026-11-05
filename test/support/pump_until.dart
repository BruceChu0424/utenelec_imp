import 'package:flutter_test/flutter_test.dart';

/// Waits for a concrete UI result while an intentionally held request may keep
/// a loading animation alive. Completing that request remains the test's job.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = tester.binding.clock.fromNowBy(timeout);
  do {
    await tester.pump(const Duration(milliseconds: 16));
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
