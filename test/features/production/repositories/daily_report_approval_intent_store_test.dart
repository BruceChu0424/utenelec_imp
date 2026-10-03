import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/daily_report_approval_intent.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/repositories/daily_report_approval_intent_store.dart';
import '../../../support/memory_cas_storage.dart';

ProductionDailyReportDetail _detail(Map<String, dynamic> extra) =>
    ProductionDailyReportDetail.fromJson({'id': 'dr-1', ...extra});
DailyReportApprovalIntent _review() => DailyReportApprovalIntent.review(
  _detail({'approvalCommandVersion': 2, 'rowVersion': 0}),
  '冻结的原数量与去向',
);

void main() {
  test(
    'real version zero is available; missing, negative and malformed versions never become reviewed zero',
    () {
      final real = _review();
      expect(real.commandVersion, 2);
      expect(real.expectedVersion, 0);
      for (final value in [null, -1, '0', 0.5]) {
        final detail = _detail({
          'approvalCommandVersion': 2,
          'rowVersion': value,
        });
        expect(detail.canFreezeReviewedApproval, isFalse);
        expect(
          () => DailyReportApprovalIntent.review(detail, '内容'),
          throwsStateError,
        );
      }
      expect(_detail({'approvalCommandVersion': 2}).rowVersion, 0);
      expect(
        _detail({'approvalCommandVersion': 2}).rowVersionAvailable,
        isFalse,
      );
    },
  );
  test(
    'legacy capability stays unversioned; unsupported capabilities fail closed',
    () {
      final legacy = DailyReportApprovalIntent.review(_detail({}), '旧版确认');
      expect(legacy.legacy, isTrue);
      expect(legacy.expectedVersion, isNull);
      for (final capability in [0, 3, '2', true]) {
        expect(
          () => DailyReportApprovalIntent.review(
            _detail({'approvalCommandVersion': capability, 'rowVersion': 0}),
            '内容',
          ),
          throwsStateError,
        );
      }
    },
  );
  test(
    'missing historical protocol remains legacy; V2 cannot recover a missing version from a new detail',
    () {
      final legacy = DailyReportApprovalIntent.fromJson({
        'reportId': 'dr-1',
        'idempotencyKey': 'legacy-original',
      });
      expect(legacy.commandVersion, 1);
      expect(legacy.expectedVersion, isNull);
      final current = _detail({'approvalCommandVersion': 2, 'rowVersion': 7});
      expect(current.rowVersion, 7);
      expect(
        () => DailyReportApprovalIntent.fromJson({
          'reportId': 'dr-1',
          'idempotencyKey': 'legacy-original',
          'commandVersion': 2,
        }),
        throwsFormatException,
      );
      expect(legacy.toJson().containsKey('expectedVersion'), isFalse);
    },
  );
  test(
    'one PREPARED CAS permits one claimant and records original body before dispatch',
    () async {
      final storage = MemoryCasStorage();
      final store = DailyReportApprovalIntentStore(storage, 'a_', () => true);
      final prepared = await store.begin(_review());
      expect(prepared.hasBeenDispatched, isFalse);
      final first = await store.claim(prepared);
      expect(first.hasBeenDispatched, isTrue);
      expect(first.intent.toJson(), prepared.intent.toJson());
      expect(first.raw, isNot(prepared.raw));
      await expectLater(store.claim(prepared), throwsStateError);
      expect((await store.read('dr-1'))!.raw, first.raw);
    },
  );
  test(
    'zero-dispatch prepared cancellation wins atomically before another sender can claim',
    () async {
      final storage = MemoryCasStorage();
      final store = DailyReportApprovalIntentStore(storage, 'a_', () => true);
      final prepared = await store.begin(_review());
      expect(await store.cancelPrepared(prepared), isTrue);
      await expectLater(store.claim(prepared), throwsStateError);
      expect(await store.read('dr-1'), isNull);
    },
  );
  test('old page cannot remove a claimed or newer replay attempt', () async {
    final storage = MemoryCasStorage();
    final store = DailyReportApprovalIntentStore(storage, 'a_', () => true);
    final prepared = await store.begin(_review());
    final claimed = await store.claim(prepared);
    expect(await store.cancelPrepared(prepared), isFalse);
    final replay = await store.claim(claimed);
    expect(await store.cancelUnsentClaim(claimed, prepared), isFalse);
    await expectLater(store.complete(claimed), throwsStateError);
    expect((await store.read('dr-1'))!.raw, replay.raw);
    await expectLater(
      store.cancelUnsentClaim(replay, claimed),
      throwsStateError,
    );
  });
  test(
    'a newly claimed but definitely unsent first attempt can be released using its own CAS value',
    () async {
      final storage = MemoryCasStorage();
      final store = DailyReportApprovalIntentStore(storage, 'a_', () => true);
      final prepared = await store.begin(_review());
      final claimed = await store.claim(prepared);
      expect(await store.cancelUnsentClaim(claimed, prepared), isTrue);
      expect(await store.read('dr-1'), isNull);
    },
  );
  test(
    'same payload in another owner namespace cannot be completed by the old owner record',
    () async {
      final storage = MemoryCasStorage();
      final ownerA = DailyReportApprovalIntentStore(storage, 'a_', () => true);
      final ownerB = DailyReportApprovalIntentStore(storage, 'b_', () => true);
      final a = await ownerA.begin(_review());
      final b = await ownerB.begin(_review());
      expect(a.raw, b.raw);
      await expectLater(ownerB.complete(a), throwsStateError);
      expect((await ownerB.read('dr-1'))!.raw, b.raw);
    },
  );
  test(
    'records without a phase are dispatched unknown and can never be cancelled as prepared',
    () async {
      final storage = MemoryCasStorage();
      final store = DailyReportApprovalIntentStore(storage, 'a_', () => true);
      storage.records['a_dr-1'] = jsonEncode({
        'reportId': 'dr-1',
        'idempotencyKey': 'legacy-original',
      });
      final old = (await store.read('dr-1'))!;
      expect(old.hasBeenDispatched, isTrue);
      expect(old.intent.legacy, isTrue);
      await expectLater(store.cancelPrepared(old), throwsStateError);
      expect(storage.records, hasLength(1));
    },
  );
  test(
    'owner change while a claim is persisted keeps evidence under the old owner',
    () async {
      final storage = MemoryCasStorage();
      var active = true;
      final store = DailyReportApprovalIntentStore(storage, 'a_', () => active);
      final prepared = await store.begin(_review());
      final gate = Completer<void>();
      storage.writeGate = gate.future;
      final claim = store.claim(prepared);
      active = false;
      gate.complete();
      await expectLater(claim, throwsStateError);
      final restored = await DailyReportApprovalIntentStore(
        storage,
        'a_',
        () => true,
      ).read('dr-1');
      expect(restored!.hasBeenDispatched, isTrue);
      expect(restored.intent.expectedVersion, 0);
    },
  );
  test(
    'failed persistence leaves no claim and unsupported local schema is preserved',
    () async {
      final storage = MemoryCasStorage()..failWrites = true;
      final store = DailyReportApprovalIntentStore(storage, 'a_', () => true);
      await expectLater(store.begin(_review()), throwsStateError);
      expect(storage.records, isEmpty);
      storage.failWrites = false;
      storage.records['a_dr-1'] = jsonEncode({
        ..._review().toJson(),
        'phase': 'FUTURE',
      });
      await expectLater(store.read('dr-1'), throwsFormatException);
      expect(storage.records, hasLength(1));
    },
  );
}
