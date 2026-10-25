import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_claim_event.dart';
import 'package:uten_imp/features/expense/widgets/expense_claim_print.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_slice_table.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';

void main() {
  test(
    'weight metadata keeps the real instant while displaying Beijing time',
    () {
      final raw = <String, dynamic>{
        'goodsId': 'goods',
        'lastObservedAt': '2026-10-24T18:30:00Z',
      };
      final params = WeightParams.fromJson(raw);

      expect(params.lastObservedAt, DateTime.utc(2026, 10, 24, 18, 30));
      expect(
        ChinaDateTime.formatInstant(params.lastObservedAt!),
        '2026-10-25 02:30(北京)',
      );
      expect(raw['lastObservedAt'], '2026-10-24T18:30:00Z');
    },
  );

  test('naive weight metadata means Beijing, including a device DST gap', () {
    final params = WeightParams.fromJson({
      'goodsId': 'goods',
      'lastObservedAt': '2026-03-08T02:30:00',
    });

    expect(params.lastObservedAt, DateTime.utc(2026, 3, 7, 18, 30));
    expect(
      ChinaDateTime.formatInstant(params.lastObservedAt!),
      '2026-03-08 02:30(北京)',
    );
  });

  test('expense printing formats an existing Beijing wall carrier once', () {
    final event = ExpenseClaimEvent.fromJson({
      'eventType': 'SUBMITTED',
      'actorName': '员工',
      'occurredAt': '2026-10-24T18:30:00Z',
    });
    final claim = ExpenseClaim(
      id: 'claim',
      claimNo: 'BX1',
      applicantId: 'employee',
      applicantName: '员工',
      title: '报销',
      items: const [],
      totalAmount: 0,
      status: ExpenseClaimStatus.submitted,
      createdAt: event.occurredAt,
      events: [event],
    );

    final line = expensePrintAuditLines(
      claim,
    ).singleWhere((line) => line.startsWith('提交审批'));
    expect(event.occurredAt, DateTime.utc(2026, 10, 25, 2, 30));
    expect(line, contains('2026-10-25 02:30(北京)'));
    expect(line, isNot(contains(' 10:30')));
    expect('(北京)'.allMatches(line), hasLength(1));
  });

  test(
    'quality receipt timestamps convert the offset instead of slicing ISO',
    () {
      expect(
        warehouseQualityDateTime('2026-10-24T18:30:00Z'),
        '2026-10-25 02:30(北京)',
      );
      expect(
        warehouseQualityDateTime('2026-10-25T02:30:00+08:00'),
        '2026-10-25 02:30(北京)',
      );
      expect(warehouseQualityDateTime(null), '—');
    },
  );
}
