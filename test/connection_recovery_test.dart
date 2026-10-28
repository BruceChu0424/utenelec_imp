import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';

void main() {
  test('successful automatic probe publishes one recovery epoch', () async {
    final controller = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const [Duration.zero],
      restoredDisplayDuration: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);

    controller.markDisconnected();
    expect(controller.state.phase, ConnectionRecoveryPhase.disconnected);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.phase, ConnectionRecoveryPhase.restored);
    expect(controller.state.recoveryEpoch, 1);
  });

  test(
    'failed probes stay disconnected and manual retry is coalesced',
    () async {
      final gate = Completer<bool>();
      var probes = 0;
      final controller = ConnectionRecoveryController(
        probe: () {
          probes++;
          return gate.future;
        },
        probeDelays: const [Duration(hours: 1)],
      );
      addTearDown(controller.dispose);

      controller.markDisconnected();
      final first = controller.retryNow();
      final second = controller.retryNow();
      expect(probes, 1);

      gate.complete(false);
      await Future.wait([first, second]);

      expect(probes, 1);
      expect(controller.state.phase, ConnectionRecoveryPhase.disconnected);
      expect(controller.state.recoveryEpoch, 0);
    },
  );

  test('a retry success before full disconnect does not reload providers', () {
    final controller = ConnectionRecoveryController(probe: () async => true);
    addTearDown(controller.dispose);

    controller.markRetrying(1);
    expect(controller.state.phase, ConnectionRecoveryPhase.reconnecting);
    controller.markConnected();

    expect(controller.state.phase, ConnectionRecoveryPhase.connected);
    expect(controller.state.recoveryEpoch, 0);
  });

  test(
    'automatic recovery keeps one bounded backoff timer and stops on success',
    () {
      fakeAsync((clock) {
        var probes = 0;
        var reachable = false;
        final scheduledDelays = <Duration>[];
        final controller = ConnectionRecoveryController(
          probe: () async {
            probes++;
            return reachable;
          },
          probeDelayJitter: (delay) {
            scheduledDelays.add(delay);
            return delay;
          },
        );
        for (var notice = 0; notice < 5; notice++) {
          controller.markDisconnected();
        }
        expect(clock.nonPeriodicTimerCount, 1);
        const delays = [
          Duration(seconds: 2),
          Duration(seconds: 5),
          Duration(seconds: 10),
          Duration(seconds: 15),
          Duration(seconds: 15),
        ];
        for (var attempt = 0; attempt < delays.length; attempt++) {
          reachable = attempt == delays.length - 1;
          clock.elapse(delays[attempt] - const Duration(milliseconds: 1));
          expect(probes, attempt);
          clock.elapse(const Duration(milliseconds: 1));
          clock.flushMicrotasks();
          expect(probes, attempt + 1);
          expect(clock.nonPeriodicTimerCount, 1);
        }
        expect(scheduledDelays, delays);
        expect(controller.state.phase, ConnectionRecoveryPhase.restored);
        expect(controller.state.recoveryEpoch, 1);
        clock.elapse(const Duration(seconds: 3));
        expect(controller.state.phase, ConnectionRecoveryPhase.connected);
        expect(clock.nonPeriodicTimerCount, 0);
        clock.elapse(const Duration(minutes: 1));
        expect(probes, delays.length);
        controller.dispose();
        expect(clock.nonPeriodicTimerCount, 0);
      });
    },
  );

  test('repeated disconnects cannot overlap an automatic probe in flight', () {
    fakeAsync((clock) {
      final gate = Completer<bool>();
      var probes = 0;
      final controller = ConnectionRecoveryController(
        probe: () {
          probes++;
          return gate.future;
        },
        probeDelays: const [Duration(seconds: 1)],
        probeDelayJitter: (delay) => delay,
      );
      controller.markDisconnected();
      clock.elapse(const Duration(seconds: 1));
      expect(probes, 1);
      for (var notice = 0; notice < 5; notice++) {
        controller.markDisconnected();
      }
      clock.elapse(const Duration(minutes: 1));
      expect(probes, 1);
      expect(clock.nonPeriodicTimerCount, 0);
      gate.complete(true);
      clock.flushMicrotasks();
      expect(controller.state.phase, ConnectionRecoveryPhase.restored);
      expect(controller.state.recoveryEpoch, 1);
      controller.dispose();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });
}
