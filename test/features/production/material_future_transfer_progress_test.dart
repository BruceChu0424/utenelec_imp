import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_future_transfer.dart';
import 'package:uten_imp/features/production/models/material_future_transfer_progress.dart';

MaterialFutureTransferRecord record({
  String id = 'transfer',
  String source = 'A',
  String sourceMaterial = 'A-H',
  String target = 'B',
  String targetMaterial = 'B-H',
  double cancelled = 10,
  double received = 20,
  double pending = 10,
  double sourceShortfall = 0,
  String? warning,
}) => MaterialFutureTransferRecord(
  id: id,
  sourceAllocationId: 'allocation',
  sourceAnalysisId: source,
  sourceMaterialId: sourceMaterial,
  targetAnalysisId: target,
  targetMaterialId: targetMaterial,
  qty: 40,
  cancelledQty: cancelled,
  receivedQty: received,
  remainingQty: pending,
  status: 'PARTIAL',
  sourceVersion: 2,
  sourceFingerprint: 'source',
  targetVersion: 3,
  targetFingerprint: 'target',
  direction: 'IN',
  sourceSupplyShortfallQty: sourceShortfall,
  supplyWarning: warning,
);

void main() {
  test(
    'original plan sees effective outgoing and actual receipt separately',
    () {
      final item = record();
      final progress = MaterialFutureTransferProgress.fromRecords(
        'A',
        ['A-H', 'A-H'],
        [item, item],
      );
      expect(progress.outgoing, 30);
      expect(progress.receivedOutgoing, 20);
      expect(progress.outstandingOutgoing, 10);
      expect(progress.incoming, 0);
      expect(progress.hasRecords, isTrue);
    },
  );
  test('recipient pending does not count already received quantity twice', () {
    final item = record();
    final progress = MaterialFutureTransferProgress.fromRecords(
      'B',
      ['B-H'],
      [item],
    );
    expect(progress.incoming, 30);
    expect(progress.outstandingIncoming, 10);
    expect(progress.receivedIncoming, 20);
    expect(progress.outgoing, 0);
  });
  test(
    'index groups only exact material identities in the current analysis',
    () {
      final item = record();
      final foreign = record(
        id: 'foreign',
        source: 'C',
        sourceMaterial: 'C-H',
        target: 'D',
        targetMaterial: 'D-H',
      );
      final index = MaterialFutureTransferProgress.index('A', [
        item,
        item,
        foreign,
      ]);
      expect(index.keys, ['A-H']);
      expect(index['A-H'], [item]);
      final unrelated = MaterialFutureTransferProgress.fromRecords(
        'A',
        ['another-path'],
        [item],
      );
      expect(unrelated.hasRecords, isFalse);
    },
  );
  test('cancelled unreceived commitment remains a visible historical fact', () {
    final progress = MaterialFutureTransferProgress.fromRecords(
      'A',
      ['A-H'],
      [record(cancelled: 40, received: 0, pending: 0)],
    );
    expect(progress.hasRecords, isTrue);
    expect(progress.outgoing, 0);
    expect(progress.outstandingOutgoing, 0);
  });
  test(
    'unfulfilled source warning stays separate from the transfer quantities',
    () {
      final progress = MaterialFutureTransferProgress.fromRecords(
        'B',
        ['B-H'],
        [record(sourceShortfall: 10, warning: '原外单供给不足')],
      );
      expect(progress.hasSupplyWarning, isTrue);
      expect(progress.incoming, 30);
      expect(progress.receivedIncoming, 20);
      expect(progress.outstandingIncoming, 10);
    },
  );
  test(
    'completed or fully cancelled history does not retain an active supply warning',
    () {
      final progress = MaterialFutureTransferProgress.fromRecords(
        'A',
        ['A-H'],
        [
          record(
            cancelled: 40,
            received: 0,
            pending: 0,
            sourceShortfall: 40,
            warning: '历史不足',
          ),
        ],
      );
      expect(progress.hasRecords, isTrue);
      expect(progress.hasSupplyWarning, isFalse);
    },
  );
}
