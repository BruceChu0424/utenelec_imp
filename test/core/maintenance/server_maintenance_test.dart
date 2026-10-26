import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/maintenance/server_maintenance.dart';

const _notice = 'cf32fe33-3f9c-4839-93ba-465b1e242096';
final _now = DateTime.utc(2026, 10, 26, 12);

ServerMaintenanceSnapshot _status(
  ServerMaintenancePhase phase, {
  Duration startsIn = const Duration(minutes: 10),
}) => ServerMaintenanceSnapshot(
  phase: phase,
  serverTime: _now,
  noticeId: phase == ServerMaintenancePhase.available ? null : _notice,
  startsAt: phase == ServerMaintenancePhase.scheduled
      ? _now.add(startsIn)
      : null,
  targetVersion: 'v2.5.32',
);

void main() {
  test('uses host Date header instead of stale file/device time', () {
    final observed = maintenanceHttpDate('Mon, 26 Oct 2026 12:03:00 GMT');
    expect(observed, DateTime.utc(2026, 10, 26, 12, 3));
    expect(maintenanceHttpDate('not a date'), isNull);
    final snapshot = ServerMaintenanceSnapshot.fromJson({
      'schemaVersion': 1,
      'state': 'scheduled',
      'noticeId': _notice,
      'serverTime': '2026-10-26T12:00:00Z',
      'startsAt': '2026-10-26T12:10:00Z',
      'retryAfterSeconds': 0,
    }, observedServerTime: observed);
    expect(snapshot.serverTime, observed);
    expect(snapshot.retryAfterSeconds, 5);
  });

  test(
    'rejects unknown and incomplete state instead of inferring maintenance',
    () {
      for (final state in ['unknown', 'scheduled']) {
        expect(
          () => ServerMaintenanceSnapshot.fromJson({
            'schemaVersion': 1,
            'state': state,
            'serverTime': '2026-10-26T12:00:00Z',
          }),
          throwsFormatException,
        );
      }
    },
  );

  test('ordinary network failure never creates a maintenance screen', () async {
    final controller = ServerMaintenanceController(
      read: () => Future.error(StateError('offline')),
      ready: () async => true,
    );
    addTearDown(controller.dispose);
    await controller.checkNow();
    expect(controller.snapshot, isNull);
    expect(controller.lastCheckFailed, isTrue);
    expect(controller.shouldWarn, isFalse);
  });

  test(
    'ten minute warning and passed deadline do not authorize blocking',
    () async {
      var status = _status(
        ServerMaintenancePhase.scheduled,
        startsIn: const Duration(hours: 2),
      );
      final controller = ServerMaintenanceController(
        read: () async => status,
        ready: () async => true,
      );
      addTearDown(controller.dispose);
      await controller.checkNow();
      expect(controller.shouldWarn, isFalse);
      status = _status(ServerMaintenancePhase.scheduled);
      await controller.checkNow();
      expect(controller.shouldWarn, isTrue);
      status = _status(
        ServerMaintenancePhase.scheduled,
        startsIn: const Duration(minutes: -1),
      );
      await controller.checkNow();
      expect(controller.shouldWarn, isTrue);
      expect(controller.snapshot!.blocksWork, isFalse);
      status = _status(ServerMaintenancePhase.available);
      await controller.checkNow();
      expect(controller.shouldWarn, isFalse);
    },
  );

  test(
    'maintenance survives outage and only confirmed readiness releases it',
    () async {
      var status = _status(ServerMaintenancePhase.updating);
      var offline = false;
      var healthy = false;
      final controller = ServerMaintenanceController(
        read: () async {
          if (offline) throw StateError('offline');
          return status;
        },
        ready: () async => healthy,
      );
      addTearDown(controller.dispose);
      await controller.checkNow();
      offline = true;
      await controller.checkNow();
      expect(controller.snapshot!.blocksWork, isTrue);
      offline = false;
      status = _status(ServerMaintenancePhase.recoveryRequired);
      await controller.checkNow();
      expect(
        controller.snapshot!.phase,
        ServerMaintenancePhase.recoveryRequired,
      );
      status = _status(ServerMaintenancePhase.available);
      await controller.checkNow();
      expect(controller.snapshot!.blocksWork, isTrue);
      healthy = true;
      await controller.checkNow();
      expect(controller.snapshot!.blocksWork, isFalse);
    },
  );

  test(
    'coalesces checks and drops replies after server/controller retirement',
    () async {
      final response = Completer<ServerMaintenanceSnapshot>();
      var reads = 0;
      final controller = ServerMaintenanceController(
        read: () {
          reads++;
          return response.future;
        },
        ready: () async => true,
      );
      final pending = controller.checkNow();
      await controller.checkNow();
      expect(reads, 1);
      controller.dispose();
      response.complete(_status(ServerMaintenancePhase.updating));
      await pending;
      expect(controller.snapshot, isNull);
    },
  );

  testWidgets('hidden clients pause polling and resume with a fresh read', (
    tester,
  ) async {
    var reads = 0;
    final controller = ServerMaintenanceController(
      read: () async {
        reads++;
        return _status(ServerMaintenancePhase.available);
      },
      ready: () async => true,
    );
    controller.setVisible(true);
    await tester.pump();
    expect(reads, 1);
    controller.setVisible(false);
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 1);
    controller.setVisible(true);
    await tester.pump();
    expect(reads, 2);
    controller.dispose();
  });
}
