import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/employee_account_batch_provision_flow.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

const _confirm = ValueKey('confirm-batch-provision-accounts');
const _dialog = ValueKey('batch-provision-accounts-dialog');
const _targets = [
  EmployeeAccountProvisionTarget(id: 'a', name: '员工甲', code: 'UT001'),
  EmployeeAccountProvisionTarget(id: 'b', name: '员工乙', code: 'UT002'),
];

void main() {
  testWidgets(
    'one batch confirmation provisions sequentially with each credential acknowledgement',
    (tester) async {
      final repository = _Repository();
      await _open(tester, repository);
      expect(find.text('员工甲（UT001）'), findsOneWidget);
      expect(find.text('员工乙（UT002）'), findsOneWidget);
      expect(repository.writes, isEmpty);
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(repository.writes, ['a']);
      expect(find.text('test-password-a'), findsOneWidget);
      await tester.tap(find.text('我已妥善保存'));
      await tester.pumpAndSettle();
      expect(repository.writes, ['a', 'b']);
      expect(find.text('test-password-b'), findsOneWidget);
      await tester.tap(find.text('我已妥善保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已开通 2 人'), findsOneWidget);
      expect(find.byKey(_confirm), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown write result stops queue and offers no retry', (
    tester,
  ) async {
    final repository = _Repository()..errors['a'] = NetworkTimeoutException();
    await _open(tester, repository);
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(repository.writes, ['a']);
    expect(find.textContaining('暂勿重复开通'), findsOneWidget);
    expect(find.textContaining('待核对 1 人 · 未处理 1 人'), findsOneWidget);
    expect(find.byKey(_confirm), findsNothing);
  });

  testWidgets(
    'known rejection is reported per employee while others can complete',
    (tester) async {
      final repository = _Repository()
        ..errors['a'] = ApiException('CONFLICT', '该员工已开通账号', httpStatus: 409);
      await _open(tester, repository);
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(repository.writes, ['a', 'b']);
      await tester.tap(find.text('我已妥善保存'));
      await tester.pumpAndSettle();
      expect(find.text('该员工已开通账号'), findsOneWidget);
      expect(find.textContaining('已开通 1 人 · 未开通 1 人'), findsOneWidget);
    },
  );

  testWidgets('missing phone is blocked before batch write', (tester) async {
    final repository = _Repository()..missingPhone.add('a');
    await _open(tester, repository);
    expect(find.text('开通 1 个账号'), findsOneWidget);
    expect(find.text('缺少手机号，请先在员工档案补全'), findsOneWidget);
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(repository.writes, ['b']);
    await tester.tap(find.text('我已妥善保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未开通 1 人'), findsOneWidget);
  });

  testWidgets(
    'owner invalidation discards late credentials and stops remaining writes',
    (tester) async {
      final owner = ValueNotifier(0);
      addTearDown(owner.dispose);
      var current = true;
      final pending = Completer<EmployeeOnboardingResult>();
      final repository = _Repository()..pending = pending;
      await _open(
        tester,
        repository,
        isCurrent: () => current,
        ownerChanges: owner,
      );
      await tester.tap(find.byKey(_confirm));
      await tester.pump();
      expect(repository.writes, ['a']);
      current = false;
      owner.value++;
      await tester.pumpAndSettle();
      pending.complete(_result('a'));
      await tester.pumpAndSettle();
      expect(repository.writes, ['a']);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.text('test-password-a'), findsNothing);
    },
  );
}

Future<void> _open(
  WidgetTester tester,
  _Repository repository, {
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) async {
  tester.view.physicalSize = const Size(1100, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = ApiClient(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue({Perm.accountSupport}),
        employeeRepositoryProvider.overrideWithValue(repository),
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: const AuthenticatedScope(userId: 'hr'),
            api: api,
            permissions: {Perm.accountSupport},
            superAdmin: false,
          ),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showProvisionSelectedEmployeeAccountsFlow(
                context,
                ref: ref,
                employees: _targets,
                isCurrent: isCurrent,
                ownerChanges: ownerChanges,
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
}

EmployeeOnboardingResult _result(String id) => EmployeeOnboardingResult(
  employee: EmployeeProfile(id: id, code: 'UT00$id', fullName: '员工$id'),
  temporaryPassword: 'test-password-$id',
  loginAccount: '1380000000$id',
);

class _Repository extends Fake implements EmployeeRepository {
  final writes = <String>[];
  final errors = <String, Object>{};
  final missingPhone = <String>{};
  Completer<EmployeeOnboardingResult>? pending;

  @override
  Future<EmployeeAccountReadiness> accountReadiness(String id) async =>
      EmployeeAccountReadiness(hasPhone: !missingPhone.contains(id));

  @override
  Future<EmployeeOnboardingResult> provisionAccount(String id) async {
    writes.add(id);
    if (errors[id] case final error?) throw error;
    if (pending != null) return pending!.future;
    return _result(id);
  }
}
