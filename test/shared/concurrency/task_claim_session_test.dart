import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/concurrency/task_claim_session.dart';
import 'package:uten_imp/shared/models/task_claim_view.dart';
import '../../helpers/finance_claim_fixture.dart';

void main() {
  test(
    'strict decisions require an owned matching live lease and revalidate its UUID',
    () async {
      final repo = FinanceClaimFixture();
      final session = TaskClaimSession(repo, strict: true);
      expect(session.blocked, isTrue);
      await session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
      expect(session.isReady, isTrue);
      expect(await session.validateForDecision(), isTrue);
      expect(repo.renewed, ['a']);
      await session.releaseAll();
      expect(session.isReady, isFalse);
      expect(repo.released, ['lease-SALES_ORDER_FINANCE_CONFIRM-a-1']);
    },
  );

  test('network failure never enables strict decisions', () async {
    final repo = FinanceClaimFixture()..failClaim = true;
    final session = TaskClaimSession(repo, strict: true);
    await session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
    expect(session.blocked, isTrue);
    expect(await session.validateForDecision(), isFalse);
    expect(repo.renewed, isEmpty);
    await session.releaseAll();
  });

  test(
    'server rejection retains its reason through a blocked decision check',
    () async {
      for (final error in [
        ApiException(
          'FORBIDDEN',
          '没有销售订单财务确认权限',
          httpStatus: 403,
          hasResponseCode: true,
        ),
        ApiException(
          'CONFLICT',
          '李四正在审核此单据，请稍后重试',
          httpStatus: 409,
          hasResponseCode: true,
        ),
        ApiException('BUSINESS', '订单已撤回，请刷新待办列表', hasResponseCode: true),
      ]) {
        final repo = FinanceClaimFixture()..claimError = error;
        final session = TaskClaimSession(repo, strict: true);
        await session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
        expect(session.isReady, isFalse);
        expect(session.failureMessage, error.message);
        expect(await session.validateForDecision(), isFalse);
        expect(session.failureMessage, error.message);
        expect(repo.renewed, isEmpty);
        await session.releaseAll();
      }
    },
  );

  test(
    'heartbeat rejection pauses decisions and retains the server reason',
    () async {
      final repo = FinanceClaimFixture();
      final session = TaskClaimSession(repo, strict: true);
      await session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
      repo.heartbeatError = ApiException('FORBIDDEN', '审核权限已被收回，请联系权限管理员');
      expect(await session.validateForDecision(), isFalse);
      expect(session.failureMessage, '审核权限已被收回，请联系权限管理员');
      expect(await session.validateForDecision(), isFalse);
      expect(session.failureMessage, '审核权限已被收回，请联系权限管理员');
      expect(repo.renewed, ['a']);
      await session.releaseAll();
    },
  );

  test(
    'local network and unknown failures use the selected language without guessing a permission cause',
    () async {
      for (final language in ['en', 'ko']) {
        final l10n = lookupAppLocalizations(Locale(language));
        for (final (error, expected) in <(Object, String)>[
          (NetworkException(), l10n.taskClaimNetworkUnavailable),
          (NetworkTimeoutException(), l10n.taskClaimNetworkTimeout),
          (
            StateError('internal detail must not be shown'),
            l10n.taskClaimAcquireFailed,
          ),
          (StateError('当前单据正在恢复，请稍后重试'), '当前单据正在恢复，请稍后重试'),
          (ApiException('FORBIDDEN', ''), l10n.taskClaimPermissionDenied),
          (ApiException('CONFLICT', ''), l10n.taskClaimConflict),
        ]) {
          final repo = FinanceClaimFixture()..claimError = error;
          final session = TaskClaimSession(
            repo,
            strict: true,
            localizations: l10n,
          );
          await session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
          expect(session.isReady, isFalse);
          expect(session.failureMessage, expected);
          await session.releaseAll();
        }
      }
    },
  );

  test(
    'identity changes replace a previous error with the current identity instruction',
    () async {
      var current = true;
      final repo = FinanceClaimFixture()
        ..claimError = ApiException('BUSINESS', '原单据状态已变化');
      final session = TaskClaimSession(
        repo,
        strict: true,
        isCurrentSession: () => current,
      );
      await session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
      current = false;
      expect(await session.validateForDecision(), isFalse);
      expect(session.failureMessage, '登录身份已变化，请重新打开审核。');
      await session.releaseAll();
    },
  );

  test('empty and mismatched ownership responses are rejected', () async {
    for (final wrongTarget in [false, true]) {
      final repo = FinanceClaimFixture()
        ..pendingClaim = Completer<TaskClaimView?>();
      final session = TaskClaimSession(repo, strict: true);
      final pending = session.claimAll('PROCUREMENT_FINANCE_APPROVE', [
        'case-a',
      ]);
      repo.pendingClaim!.complete(
        wrongTarget
            ? repo.lease('PROCUREMENT_FINANCE_APPROVE', 'case-b')
            : null,
      );
      await pending;
      expect(session.isReady, isFalse);
      await session.releaseAll();
    }
  });

  testWidgets(
    'a failed periodic heartbeat pauses decisions and stops renewal',
    (tester) async {
      final repo = FinanceClaimFixture();
      final session = TaskClaimSession(repo, strict: true);
      await session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
      repo.failHeartbeat = true;
      await tester.pump(const Duration(seconds: 31));
      expect(session.isReady, isFalse);
      expect(repo.renewed, ['a']);
      await tester.pump(const Duration(seconds: 31));
      expect(repo.renewed, ['a']);
      await session.releaseAll();
    },
  );

  test(
    'same employee with a replacement lease cannot renew the old review',
    () async {
      final repo = FinanceClaimFixture();
      final session = TaskClaimSession(repo, strict: true);
      await session.claimAll('PROCUREMENT_FINANCE_APPROVE', ['a']);
      repo.loseLease = true;
      expect(await session.validateForDecision(), isFalse);
      expect(session.failureMessage, contains('被接管'));
      await session.releaseAll();
    },
  );

  test(
    'disposed session ignores late acquisition and releases only that lease UUID',
    () async {
      final repo = FinanceClaimFixture()
        ..pendingClaim = Completer<TaskClaimView?>();
      final session = TaskClaimSession(repo, strict: true);
      var changes = 0;
      session.addListener(() => changes++);
      final pending = session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
      await session.releaseAll();
      final changesAtClose = changes;
      repo.leases['a'] = repo.lease(
        'SALES_ORDER_FINANCE_CONFIRM',
        'a',
        id: 'new-window-lease',
      );
      repo.pendingClaim!.complete(
        repo.lease('SALES_ORDER_FINANCE_CONFIRM', 'a', id: 'old-window-lease'),
      );
      await pending;
      expect(changes, changesAtClose);
      expect(session.isReady, isFalse);
      expect(repo.released, ['old-window-lease']);
      expect(repo.leases['a']!.claimId, 'new-window-lease');
    },
  );

  test(
    'identity replacement rejects late responses and does not release under another identity',
    () async {
      var identity = Object();
      final captured = identity;
      final repo = FinanceClaimFixture()
        ..pendingClaim = Completer<TaskClaimView?>();
      final session = TaskClaimSession(
        repo,
        strict: true,
        isCurrentSession: () => identical(identity, captured),
      );
      final pending = session.claimAll('SALES_ORDER_FINANCE_CONFIRM', ['a']);
      identity = Object();
      repo.pendingClaim!.complete(
        repo.lease('SALES_ORDER_FINANCE_CONFIRM', 'a'),
      );
      await pending;
      identity =
          Object(); // Returning to the same employee still creates a new session.
      expect(await session.validateForDecision(), isFalse);
      await session.releaseAll();
      expect(repo.renewed, isEmpty);
      expect(repo.released, isEmpty);
    },
  );

  test(
    'retry creates a fresh acquisition and never automatically revives a failed lease',
    () async {
      final repo = FinanceClaimFixture()..failClaim = true;
      final failed = TaskClaimSession(repo, strict: true);
      await failed.claimAll('PROCUREMENT_FINANCE_APPROVE', ['a']);
      repo.failClaim = false;
      expect(await failed.validateForDecision(), isFalse);
      await failed.releaseAll();
      final retry = TaskClaimSession(repo, strict: true);
      await retry.claimAll('PROCUREMENT_FINANCE_APPROVE', ['a']);
      expect(retry.isReady, isTrue);
      await retry.releaseAll();
    },
  );
}
