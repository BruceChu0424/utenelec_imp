import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';

void main() {
  test(
    'authoritative action counts and scope targets override item fallback',
    () {
      final preview = DataHandoverPreview.fromJson({
        'sourceEmployeeId': 'source-1',
        'targetEmployeeId': 'default-1',
        'scopes': ['client', 'finance'],
        'items': [
          {
            'key': 'client.owner',
            'label': '负责客户',
            'scope': 'client',
            'count': 99,
            'action': 'TRANSFER',
          },
        ],
        'hasBlockers': false,
        'requiresTarget': true,
        'transferCount': 4,
        'historyAccessCount': 8,
        'releaseCount': 2,
        'blockingCount': 0,
        'total': 14,
        'scopeTargetEmployeeIds': {
          'client': 'default-1',
          'finance': 'existing-1',
        },
        'scopeTargetEmployeeNames': {'client': '默认接手人', 'finance': '既有接手人'},
      });

      expect(preview.actionCount(DataHandoverAction.transfer), 4);
      expect(preview.actionCount(DataHandoverAction.historyAccess), 8);
      expect(preview.actionCount(DataHandoverAction.release), 2);
      expect(preview.actionCount(DataHandoverAction.blocking), 0);
      expect(
        DataHandoverAction.values
            .map(preview.actionCount)
            .fold(0, (sum, count) => sum + count),
        preview.total,
      );
      expect(preview.scopeTargetEmployeeIds['finance'], 'existing-1');
      expect(preview.scopeTargetEmployeeNames['finance'], '既有接手人');
    },
  );

  test('result total uses server total without double counting it', () {
    final result = DataHandoverResult.fromJson({
      'id': 'handover-1',
      'sequenceNo': 8,
      'requestId': 'request-1',
      'sourceEmployeeId': 'source-1',
      'targetEmployeeId': 'target-1',
      'mode': 'MANUAL',
      'status': 'COMPLETED',
      'scopes': ['client'],
      'resultSummary': {'client.owner': 4, 'history.client': 3, 'total': 7},
      'replayed': false,
    });
    expect(result.processedTotal, 7);

    final legacy = DataHandoverResult.fromJson({
      'id': 'handover-2',
      'sequenceNo': 9,
      'requestId': 'request-2',
      'sourceEmployeeId': 'source-1',
      'targetEmployeeId': 'target-1',
      'mode': 'MANUAL',
      'status': 'COMPLETED',
      'scopes': ['client'],
      'resultSummary': {'client.owner': 2, 'history.client': 1},
      'replayed': false,
    });
    expect(legacy.processedTotal, 3);
  });
}
