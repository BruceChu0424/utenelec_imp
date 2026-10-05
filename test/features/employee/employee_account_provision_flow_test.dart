// 开号流程(证件问题不阻塞)：确认弹窗先读就绪检查——缺手机号红色提醒 + 确认置灰；
// 证件问题红/黄提醒但照常可确认；就绪检查失败不提醒、照常可确认；开号成功后凭据弹窗
// 按返回的员工资料显示提醒；开号失败显示服务端原话。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/models/employee_id_number_issue.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/employee_account_provision_flow.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _dialog = ValueKey('provision-selected-employee-dialog');
const _confirm = ValueKey('provision-selected-employee-confirm');
const _noPhone = ValueKey('provision-selected-employee-no-phone');
const _notice = ValueKey('employee-identity-issue-notice');

const _invalidIssue = EmployeeIdNumberIssue(
  kind: EmployeeIdNumberIssueKind.invalid,
  reason: '身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对',
);

class _ProvisionRepository extends Fake implements EmployeeRepository {
  _ProvisionRepository({
    this.readiness,
    this.readinessError,
    this.readinessPending,
    this.provisionedIssue,
    this.provisionError,
  });

  final EmployeeAccountReadiness? readiness;
  final Object? readinessError;
  final Completer<EmployeeAccountReadiness>? readinessPending;
  final EmployeeIdNumberIssue? provisionedIssue;
  final ApiException? provisionError;
  int readinessCalls = 0;
  int provisionCalls = 0;

  @override
  Future<EmployeeAccountReadiness> accountReadiness(String id) async {
    readinessCalls++;
    final pending = readinessPending;
    if (pending != null) return pending.future;
    final error = readinessError;
    if (error != null) throw error;
    return readiness!;
  }

  @override
  Future<EmployeeOnboardingResult> provisionAccount(String id) async {
    provisionCalls++;
    final error = provisionError;
    if (error != null) throw error;
    return EmployeeOnboardingResult(
      employee: EmployeeProfile(
        id: id,
        code: 'UT0007',
        fullName: '赵六',
        phone: '13800138000',
        accountStatus: 'active',
        idNumberIssue: provisionedIssue,
      ),
      temporaryPassword: '00218X',
      loginAccount: '13800138000',
    );
  }
}

Future<void> _openFlow(WidgetTester tester, _ProvisionRepository repo) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeeRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.accountSupport,
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showProvisionSelectedEmployeeAccountFlow(
                context,
                ref: ref,
                employeeId: 'emp-7',
                employeeName: '赵六',
                employeeCode: 'UT0007',
                hasAccount: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byKey(_dialog), findsOneWidget);
}

VoidCallback? _confirmPressed(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(_confirm)).onPressed;

UtenInlineNotice _identityNotice(WidgetTester tester) =>
    tester.widget<UtenInlineNotice>(
      find.descendant(
        of: find.byKey(_notice),
        matching: find.byType(UtenInlineNotice),
      ),
    );

void main() {
  setUp(UtenBusyOverlay.debugResetYield);

  testWidgets('证件校验未通过：确认前红色提醒且仍可开通，凭据弹窗也提醒', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _ProvisionRepository(
      readiness: const EmployeeAccountReadiness(
        hasPhone: true,
        idNumberIssue: _invalidIssue,
      ),
      provisionedIssue: _invalidIssue,
    );
    await _openFlow(tester, repo);

    expect(repo.readinessCalls, 1);
    expect(find.byKey(_noPhone), findsNothing);
    expect(_identityNotice(tester).level, UtenInlineNoticeLevel.error);
    expect(find.textContaining(_invalidIssue.reason), findsOneWidget);
    expect(find.textContaining('可以继续开通，不受影响'), findsOneWidget);
    expect(_confirmPressed(tester), isNotNull, reason: '证件问题不阻塞开号');

    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();

    expect(repo.provisionCalls, 1);
    expect(find.byKey(_dialog), findsNothing);
    expect(find.text('账号已创建'), findsOneWidget);
    expect(find.text('00218X'), findsOneWidget);
    expect(_identityNotice(tester).level, UtenInlineNoticeLevel.error);
    expect(find.textContaining('请把这里显示的密码告诉员工'), findsOneWidget);
  });

  testWidgets('没有手机号：红色提醒，确认置灰，不发开号请求', (tester) async {
    final repo = _ProvisionRepository(
      readiness: const EmployeeAccountReadiness(
        hasPhone: false,
        idNumberIssue: EmployeeIdNumberIssue(
          kind: EmployeeIdNumberIssueKind.missing,
          reason: '档案里没有证件号码',
        ),
      ),
    );
    await _openFlow(tester, repo);

    final phoneNotice = tester.widget<UtenInlineNotice>(find.byKey(_noPhone));
    expect(phoneNotice.level, UtenInlineNoticeLevel.error);
    expect(phoneNotice.message, contains('没有手机号'));
    expect(_identityNotice(tester).level, UtenInlineNoticeLevel.warning);
    expect(_confirmPressed(tester), isNull);

    await tester.tap(find.byKey(_confirm), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(repo.provisionCalls, 0);
  });

  testWidgets('就绪检查失败：不额外提醒，照常可确认', (tester) async {
    final repo = _ProvisionRepository(
      readinessError: ApiException('INTERNAL', '服务器繁忙，请稍后再试'),
    );
    await _openFlow(tester, repo);

    expect(find.byKey(_noPhone), findsNothing);
    expect(find.byKey(_notice), findsNothing);
    expect(_confirmPressed(tester), isNotNull);

    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(repo.provisionCalls, 1);
    expect(find.text('账号已创建'), findsOneWidget);
    expect(find.byKey(_notice), findsNothing, reason: '返回资料没有证件问题，凭据弹窗不提醒');
  });

  testWidgets('就绪检查进行中确认按钮先锁住', (tester) async {
    final pending = Completer<EmployeeAccountReadiness>();
    final repo = _ProvisionRepository(readinessPending: pending);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeRepositoryProvider.overrideWithValue(repo),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.accountSupport,
          }),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showProvisionSelectedEmployeeAccountFlow(
                  context,
                  ref: ref,
                  employeeId: 'emp-7',
                  employeeName: '赵六',
                  hasAccount: false,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(_dialog), findsOneWidget);
    expect(_confirmPressed(tester), isNull);

    pending.complete(const EmployeeAccountReadiness(hasPhone: true));
    await tester.pumpAndSettle();
    expect(_confirmPressed(tester), isNotNull);
    expect(find.byKey(_notice), findsNothing);
  });

  testWidgets('开号失败时弹窗里显示服务端原话', (tester) async {
    final repo = _ProvisionRepository(
      readiness: const EmployeeAccountReadiness(hasPhone: true),
      provisionError: ApiException('CONFLICT', '该手机号已被其他账号用作登录名，无法开通'),
    );
    await _openFlow(tester, repo);

    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();

    expect(find.byKey(_dialog), findsOneWidget);
    expect(find.text('该手机号已被其他账号用作登录名，无法开通'), findsOneWidget);
    expect(find.text('开通账号失败，请稍后重试'), findsNothing);
    expect(_confirmPressed(tester), isNotNull);
  });
}
