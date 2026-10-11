import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/daily_report_material_review.dart';
import 'package:uten_imp/features/production/models/daily_report_approval_intent.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/repositories/daily_report_approval_intent_store.dart';
import '../../support/memory_cas_storage.dart';

Map<String, dynamic> _row({bool canReturn = true}) => {
  'demandId': 'demand-a',
  'planId': 'plan-a',
  'materialExecutionSegmentId': 'segment-a',
  'availableQty': 10,
  'usageQty': 6,
  'remainingIssuedQty': 4,
  'undrawnDirectQty': 2,
  'returnableIssuedQty': canReturn ? 4 : 0,
  'returnableDirectQty': canReturn ? 2 : 0,
  'canReturn': canReturn,
};
DailyReportMaterialReview _review({List<Map<String, dynamic>>? rows}) =>
    DailyReportMaterialReview.fromJson({
      'reportId': 'dr-1',
      'reportVersion': 0,
      'fingerprint': 'original-material-snapshot',
      'rows': rows ?? [_row()],
    });
ProductionDailyReportDetail _detail() => ProductionDailyReportDetail.fromJson({
  'id': 'dr-1',
  'approvalCommandVersion': 3,
  'rowVersion': 0,
});

void main() {
  test(
    'saved usage preserves exact decimals and never guesses large legacy quantities',
    () {
      final exact = ProductionDailyReportMaterialUsage.fromJson({
        'demandId': 'demand-a',
        'qtyBase': 10000000000000.0,
        'qtyBaseExact': '9999999999999.9999',
      });
      expect(exact.qtyBaseText, '9999999999999.9999');
      expect(
        ProductionDailyReportMaterialUsage.fromJson({
          'demandId': 'demand-a',
          'qtyBase': 10000000000000.0,
        }).qtyBaseText,
        isNull,
      );
    },
  );
  test(
    'V3 durable CAS keeps original exact snapshot and decisions across recovery',
    () async {
      final intent = DailyReportApprovalIntent.review(
        _detail(),
        '确认',
        materialReview: _review(),
        materialActions: {
          'demand-a': DailyReportMaterialAction.returnToWarehouse,
        },
      );
      final store = DailyReportApprovalIntentStore(
        MemoryCasStorage(),
        'owner_',
        () => true,
      );
      final prepared = await store.begin(intent);
      final claimed = await store.claim(prepared);
      final restored = (await store.read('dr-1'))!;
      expect(restored.intent.toJson(), claimed.intent.toJson());
      expect(
        restored.intent.materialReview!.rows.single.remainingIssuedQty,
        '4',
      );
      expect(
        restored.intent.materialDecisions.single.action,
        DailyReportMaterialAction.returnToWarehouse,
      );
    },
  );
  test(
    'review needs a complete source and exact server quantities; duplicates are rejected',
    () {
      expect(() => _review(rows: [_row(), _row()]), throwsFormatException);
      for (final key in [
        'availableQty',
        'usageQty',
        'remainingIssuedQty',
        'undrawnDirectQty',
        'returnableIssuedQty',
        'returnableDirectQty',
      ]) {
        expect(
          () => _review(rows: [_row()..remove(key)]),
          throwsFormatException,
        );
      }
      expect(
        () => _review(rows: [_row()..['canReturn'] = 'true']),
        throwsFormatException,
      );
    },
  );
  test(
    'large exact balances retain decimal source rather than rounded JSON numbers',
    () {
      final row = _row()
        ..['availableQty'] = 100000000000.1234
        ..['availableQtyExact'] = '100000000000.1234'
        ..['returnableIssuedQtyExact'] = '100000000000.1234'
        ..['returnableDirectQtyExact'] = '0.0001';
      final parsed = _review(rows: [row]).rows.single;
      expect(parsed.availableQty, '100000000000.1234');
      expect(parsed.returnableQty, '100000000000.1235');
      row.remove('availableQtyExact');
      expect(() => _review(rows: [row]), throwsFormatException);
    },
  );
  test(
    'only eligible balances require choices; blocked and zero rows freeze KEEP',
    () {
      final blocked = _review(rows: [_row(canReturn: false)]);
      expect(
        blocked
            .freezeDecisions({
              'demand-a': DailyReportMaterialAction.returnToWarehouse,
            })
            .single
            .action,
        DailyReportMaterialAction.keep,
      );
      expect(() => _review().freezeDecisions({}), throwsStateError);
      final zero = _row()
        ..['remainingIssuedQty'] = 0
        ..['undrawnDirectQty'] = 0;
      expect(
        _review(rows: [zero]).freezeDecisions({}).single.action,
        DailyReportMaterialAction.keep,
      );
    },
  );
  test(
    'V3 freezes decisions and changes key when either decision or ledger changes',
    () {
      final actions = {'demand-a': DailyReportMaterialAction.keep};
      final kept = DailyReportApprovalIntent.review(
        _detail(),
        '确认',
        materialReview: _review(),
        materialActions: actions,
      );
      actions['demand-a'] = DailyReportMaterialAction.returnToWarehouse;
      expect(
        kept.materialDecisions.single.action,
        DailyReportMaterialAction.keep,
      );
      final returned = DailyReportApprovalIntent.review(
        _detail(),
        '确认',
        materialReview: _review(),
        materialActions: actions,
      );
      expect(returned.idempotencyKey, isNot(kept.idempotencyKey));
      expect(
        DailyReportApprovalIntent.fromJson(returned.toJson()).toJson(),
        returned.toJson(),
      );
      expect(() => returned.materialDecisions.clear(), throwsUnsupportedError);
    },
  );
  test('V3 cannot be frozen with a missing or wrong report snapshot', () {
    expect(
      () => DailyReportApprovalIntent.review(_detail(), '确认'),
      throwsStateError,
    );
    final changed = DailyReportMaterialReview(
      reportId: 'dr-1',
      reportVersion: 1,
      fingerprint: 'changed',
      rows: _review().rows,
    );
    expect(
      () => DailyReportApprovalIntent.review(
        _detail(),
        '确认',
        materialReview: changed,
        materialActions: {'demand-a': DailyReportMaterialAction.keep},
      ),
      throwsStateError,
    );
  });
  test(
    'recovery never backfills missing decisions or material fingerprint from new GET',
    () {
      final intent = DailyReportApprovalIntent.review(
        _detail(),
        '确认',
        materialReview: _review(),
        materialActions: {'demand-a': DailyReportMaterialAction.keep},
      );
      for (final key in [
        'materialReviewFingerprint',
        'materialDecisions',
        'materialReview',
        'expectedVersion',
      ]) {
        expect(
          () =>
              DailyReportApprovalIntent.fromJson(intent.toJson()..remove(key)),
          throwsFormatException,
        );
      }
      final duplicated = intent.toJson()
        ..['materialDecisions'] = [
          {'demandId': 'demand-a', 'action': 'KEEP'},
          {'demandId': 'demand-a', 'action': 'RETURN'},
        ];
      expect(
        () => DailyReportApprovalIntent.fromJson(duplicated),
        throwsFormatException,
      );
    },
  );
  test(
    'V3 receipt verifies the frozen ledger snapshot as well as report, key and version',
    () {
      final intent = DailyReportApprovalIntent.review(
        _detail(),
        '确认',
        materialReview: _review(),
        materialActions: {'demand-a': DailyReportMaterialAction.keep},
      );
      Map<String, dynamic> receipt() => {
        'reportId': intent.reportId,
        'idempotencyKey': intent.idempotencyKey,
        'commandVersion': 3,
        'reviewedVersion': 0,
        'materialReviewFingerprint': intent.materialReviewFingerprint,
        'reviewProtection': 'REVIEWED_MATERIAL_SNAPSHOT',
      };
      expect(
        intent.verifiedReceipt(
          ProductionDailyReportApprovalReceipt.fromJson(receipt()),
        ),
        isTrue,
      );
      expect(
        intent.verifiedReceipt(
          ProductionDailyReportApprovalReceipt.fromJson(
            receipt()..['materialReviewFingerprint'] = 'new-snapshot',
          ),
        ),
        isFalse,
      );
      expect(
        ProductionDailyReportApprovalReceipt.fromJson(
          receipt()..remove('materialReviewFingerprint'),
        ).valid,
        isFalse,
      );
    },
  );
}
