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
