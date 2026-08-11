import 'dart:async';

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
}
