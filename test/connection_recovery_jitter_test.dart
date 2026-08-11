import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';

void main() {
  test('production probe jitter stays within the configured upper bound', () {
    const base = Duration(seconds: 15);
    const minimum = Duration(milliseconds: 12750);

    for (var i = 0; i < 100; i++) {
      final actual = randomizedProbeDelay(base);
      expect(actual, greaterThanOrEqualTo(minimum));
      expect(actual, lessThanOrEqualTo(base));
    }
    expect(randomizedProbeDelay(Duration.zero), Duration.zero);
  });

  test('automatic probe uses the injected jitter policy', () async {
    final observedBaseDelays = <Duration>[];
    var probes = 0;
    final controller = ConnectionRecoveryController(
      probe: () async {
        probes++;
        return true;
      },
      probeDelays: const <Duration>[Duration(seconds: 15)],
      probeDelayJitter: (baseDelay) {
        observedBaseDelays.add(baseDelay);
        return Duration.zero;
      },
      restoredDisplayDuration: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    controller.markDisconnected();
    await pumpEventQueue();

    expect(observedBaseDelays, const <Duration>[Duration(seconds: 15)]);
    expect(probes, 1);
    expect(controller.state.phase, ConnectionRecoveryPhase.restored);
    expect(controller.state.recoveryEpoch, 1);
  });

  test('retryNow bypasses a scheduled jittered delay', () async {
    var jitterCalls = 0;
    var probes = 0;
    final controller = ConnectionRecoveryController(
      probe: () async {
        probes++;
        return true;
      },
      probeDelays: const <Duration>[Duration(minutes: 10)],
      probeDelayJitter: (baseDelay) {
        jitterCalls++;
        return const Duration(hours: 1);
      },
      restoredDisplayDuration: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    controller.markDisconnected();
    expect(jitterCalls, 1);
    expect(probes, 0);

    await controller.retryNow();

    expect(jitterCalls, 1);
    expect(probes, 1);
    expect(controller.state.phase, ConnectionRecoveryPhase.restored);
  });
}
