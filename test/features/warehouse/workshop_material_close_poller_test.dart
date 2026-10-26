import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_close_poller.dart';

const _queued = WmCloseStatus(
  status: WmPeriodStatus.counted,
  closeState: WmCloseState.queued,
);
const _closed = WmCloseStatus(
  status: WmPeriodStatus.closed,
  closeState: WmCloseState.none,
);

void main() {
  testWidgets('restarting ignores the previous read and keeps polling', (
    tester,
  ) async {
    final oldRead = Completer<WmCloseStatus>();
    final statuses = <WmCloseStatus>[];
    var reads = 0;
    final poller = WmClosePoller(
      load: () => ++reads == 1 ? oldRead.future : Future.value(_queued),
      onStatus: statuses.add,
    );
    addTearDown(poller.stop);

    poller.start();
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);
    poller.start();
    oldRead.complete(_closed);
    await tester.pump();

    expect(statuses, isEmpty);
    expect(poller.active, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 2);
    expect(statuses, [_queued]);
    poller.stop();
  });

  testWidgets('reads never overlap and stopping retires an in-flight read', (
    tester,
  ) async {
    final read = Completer<WmCloseStatus>();
    final statuses = <WmCloseStatus>[];
    var reads = 0;
    final poller = WmClosePoller(
      load: () {
        reads++;
        return read.future;
      },
      onStatus: statuses.add,
    );
    poller.start();
    await tester.pump(const Duration(seconds: 10));
    expect(reads, 1);
    poller.stop();
    read.complete(_closed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(statuses, isEmpty);
    expect(reads, 1);
    expect(poller.active, isFalse);
  });

  testWidgets(
    'a status callback can restart without the old read stopping it',
    (tester) async {
      var reads = 0;
      late WmClosePoller poller;
      poller = WmClosePoller(
        load: () async => ++reads == 1 ? _closed : _queued,
        onStatus: (status) {
          if (identical(status, _closed)) poller.start();
        },
      );
      addTearDown(poller.stop);
      poller.start();
      await tester.pump(const Duration(seconds: 2));
      expect(poller.active, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(reads, 2);
      poller.stop();
    },
  );

  testWidgets('failed reads retain the configured attempt limit', (
    tester,
  ) async {
    var reads = 0;
    final poller = WmClosePoller(
      maxTicks: 2,
      load: () async {
        reads++;
        throw StateError('temporary read failure');
      },
      onStatus: (_) => fail('failed read published a status'),
    );
    poller.start();
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(seconds: 2));
    }
    expect(reads, 2);
    expect(poller.active, isFalse);
  });
}
