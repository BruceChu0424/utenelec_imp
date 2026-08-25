import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';

void main() {
  test('preview parses stable actions and groups', () {
    final preview = DataHandoverPreview.fromJson({
      'sourceEmployeeId': 'source-1',
      'targetEmployeeId': 'target-1',
      'scopes': ['client', 'sales'],
      'items': [
        {
          'key': 'client.owner',
          'label': '负责客户',
          'scope': 'client',
          'count': 4,
          'action': 'TRANSFER',
        },
        {
          'key': 'sales.history',
          'label': '销售历史',
          'scope': 'sales',
          'count': 8,
          'action': 'HISTORY_ACCESS',
        },
      ],
      'hasBlockers': false,
      'requiresTarget': true,
      'total': 12,
    });

    expect(preview.sourceEmployeeId, 'source-1');
    expect(preview.requiresTarget, isTrue);
    expect(preview.total, 12);
    expect(preview.items.first.action, DataHandoverAction.transfer);
    expect(preview.items.last.action, DataHandoverAction.historyAccess);
  });

  test('unknown action fails closed as a blocker', () {
    final preview = DataHandoverPreview.fromJson({
      'sourceEmployeeId': 'source-1',
      'scopes': <String>[],
      'items': [
        {
          'key': 'future.rule',
          'label': '未来规则',
          'scope': 'all',
          'count': 1,
          'action': 'UNKNOWN_NEW_ACTION',
        },
      ],
      'hasBlockers': false,
      'requiresTarget': false,
      'total': 1,
    });

    expect(preview.items.single.action, DataHandoverAction.blocking);
    expect(preview.blockers, hasLength(1));
  });

  test('manual request emits stable idempotency body', () {
    const request = DataHandoverRequest(
      requestId: 'request-1',
      sourceEmployeeId: 'source-1',
      targetEmployeeId: 'target-1',
      scopes: {'sales', 'client'},
      reason: '  离职补交接  ',
      effectiveDate: '2026-08-25',
    );

    expect(request.toJson(), {
      'requestId': 'request-1',
      'sourceEmployeeId': 'source-1',
      'targetEmployeeId': 'target-1',
      'scopes': ['client', 'sales'],
      'reason': '离职补交接',
      'effectiveDate': '2026-08-25',
    });
  });

  test('workflow is a preview-only scope with a clear label', () {
    expect(dataHandoverScopeLabel('workflow'), '任务认领');
    expect(isSelectableDataHandoverScope('workflow'), isFalse);
    expect(isSelectableDataHandoverScope('organization'), isFalse);
    expect(isSelectableDataHandoverScope('client'), isTrue);
  });
}
