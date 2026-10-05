// 修改证件信息弹窗：身份证不合法客户端直接拦并说清具体哪里不对；合法时带规范化后的号码；
// 可以改证件类型；绝不预填脱敏值；服务端拒绝时原话留在弹窗里；关窗前已清忙标志。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/models/employee_id_number_issue.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/employee_identity_correction_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _dialog = ValueKey('employee-identity-correction-dialog');
const _number = ValueKey('employee-identity-correction-number');
const _type = ValueKey('employee-identity-correction-type');
const _save = ValueKey('employee-identity-correction-save');
const _problem = ValueKey('employee-identity-correction-problem');
const _error = ValueKey('employee-identity-correction-error');

class _IdentityRepository extends Fake implements EmployeeRepository {
  _IdentityRepository({this.failWith, this.pending, this.loaded});

  final ApiException? failWith;
  final Completer<void>? pending;
  final EmployeeProfile? loaded;
  final calls = <(String, String, String)>[];
  int getByIdCalls = 0;

  @override
  Future<EmployeeProfile> getById(String id) async {
    getByIdCalls++;
    return loaded ?? EmployeeProfile(id: id, code: 'UT0001', fullName: '王五');
  }

  @override
  Future<void> changeIdentity(
    String id, {
    required String idType,
    required String idNumber,
  }) async {
    calls.add((id, idType, idNumber));
    final error = failWith;
    if (error != null) throw error;
    await pending?.future;
  }
}

EmployeeProfile _profile({
  String? idType = '身份证',
  String? idNumber,
  EmployeeIdNumberIssue? issue,
}) => EmployeeProfile(
  id: 'emp-1',
  code: 'UT0001',
  fullName: '王五',
  idType: idType,
  idNumber: idNumber,
  idNumberIssue: issue,
);

class _Results {
  final values = <bool>[];
}

Future<_Results> _open(
  WidgetTester tester,
  _IdentityRepository repository, {
  EmployeeProfile? profile,
  Set<String> permissions = const {Perm.employeePiiEdit},
}) async {
  final results = _Results();
  // 先卸掉上一次的整棵树(含还开着的弹窗)，同一用例里可以多次打开。
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeeRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async {
                results.values.add(
                  await showEmployeeIdentityCorrectionDialog(
                    context,
                    ref: ref,
                    employeeId: 'emp-1',
                    employeeName: '王五',
                    profile: profile,
                  ),
                );
              },
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
  return results;
}

String _numberText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_number)).controller!.text;

void main() {
  setUp(UtenBusyOverlay.debugResetYield);

  testWidgets('不合法的身份证号客户端直接拦，并写明具体哪里不对', (tester) async {
    final repository = _IdentityRepository();
    final results = await _open(tester, repository, profile: _profile());

    await tester.enterText(find.byKey(_number), '11010519491231002');
    await tester.pump();
    expect(find.byKey(_problem), findsOneWidget);
    expect(find.text('身份证号应为18位，当前为17位'), findsOneWidget);

    await tester.tap(find.byKey(_save));
    await tester.pumpAndSettle();
    expect(repository.calls, isEmpty, reason: '不合法不发请求');
    expect(find.byKey(_dialog), findsOneWidget);
    expect(results.values, isEmpty);

    // 位数对了但校验码错：说清楚是第18位校验码对不上。
    await tester.enterText(find.byKey(_number), '110105194912310021');
    await tester.pump();
    expect(
      find.text('身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对'),
      findsOneWidget,
    );

    // 清空后点保存：提示不能为空。
    await tester.enterText(find.byKey(_number), '');
    await tester.tap(find.byKey(_save));
    await tester.pump();
    expect(find.text('身份证号不能为空'), findsOneWidget);
    expect(repository.calls, isEmpty);
  });

  testWidgets('合法号码提交规范化后的号码(大写 X)和证件类型', (tester) async {
    final repository = _IdentityRepository();
    final results = await _open(tester, repository, profile: _profile());

    await tester.enterText(find.byKey(_number), '11010519491231002x');
    await tester.pump();
    expect(find.byKey(_problem), findsNothing);
    await tester.tap(find.byKey(_save));
    await tester.pumpAndSettle();

    expect(repository.calls, [('emp-1', '身份证', '11010519491231002X')]);
    expect(find.byKey(_dialog), findsNothing);
    expect(results.values, [true]);
  });

  testWidgets('切换成护照时带上新的证件类型，只要求不为空', (tester) async {
    final repository = _IdentityRepository();
    await _open(tester, repository, profile: _profile());

    tester.widget<UtenDropdownField>(find.byKey(_type)).onChanged('护照');
    await tester.pump();
    await tester.enterText(find.byKey(_number), ' E1234567A ');
    await tester.pump();
    expect(find.byKey(_problem), findsNothing);
    await tester.tap(find.byKey(_save));
    await tester.pumpAndSettle();

    expect(repository.calls, [('emp-1', '护照', 'E1234567A')]);
  });

  testWidgets('绝不预填脱敏值；能看明文时预填并当场指出问题', (tester) async {
    // 没有明文权限时服务端给的是 ****1234：不能带进输入框，并提示直接输入完整新号码。
    await _open(
      tester,
      _IdentityRepository(),
      profile: _profile(idNumber: '****1234'),
    );
    expect(_numberText(tester), isEmpty);
    expect(find.text('你没有查看证件号码明文的权限，请直接输入完整的新号码。'), findsOneWidget);

    // 不管本地权限怎么配，只要拿到的是脱敏值就不预填(以服务端脱敏结果为准)。
    await _open(
      tester,
      _IdentityRepository(),
      profile: _profile(idNumber: '****1234'),
      permissions: const {Perm.employeePiiEdit, Perm.employeePiiView},
    );
    expect(_numberText(tester), isEmpty);

    // 有明文权限 + 明文号码：预填，并直接显示具体问题和档案里的原因。
    await _open(
      tester,
      _IdentityRepository(),
      profile: _profile(
        idNumber: '11010519491231002',
        issue: const EmployeeIdNumberIssue(
          kind: EmployeeIdNumberIssueKind.invalid,
          reason: '身份证号应为18位，当前为17位',
        ),
      ),
      permissions: const {Perm.employeePiiEdit, Perm.employeePiiView},
    );
    expect(_numberText(tester), '11010519491231002');
    expect(
      find.byKey(const ValueKey('employee-identity-correction-current')),
      findsOneWidget,
    );
    expect(find.text('具体问题：身份证号应为18位，当前为17位'), findsOneWidget);
    expect(find.byKey(_problem), findsOneWidget);
  });

  testWidgets('没传资料时先读一次档案，带出当前证件类型', (tester) async {
    final repository = _IdentityRepository(
      loaded: _profile(idType: '港澳台通行证', idNumber: 'H1234567'),
    );
    await _open(
      tester,
      repository,
      permissions: const {Perm.employeePiiEdit, Perm.employeePiiView},
    );

    expect(repository.getByIdCalls, 1);
    expect(tester.widget<UtenDropdownField>(find.byKey(_type)).value, '港澳台通行证');
    expect(_numberText(tester), 'H1234567');
  });

  testWidgets('服务端拒绝时原话显示在弹窗里，弹窗不关', (tester) async {
    final repository = _IdentityRepository(
      failWith: ApiException('CONFLICT', '该证件号码已被其他员工使用'),
    );
    final results = await _open(tester, repository, profile: _profile());

    await tester.enterText(find.byKey(_number), '11010519491231002X');
    await tester.tap(find.byKey(_save));
    await tester.pumpAndSettle();

    expect(repository.calls, hasLength(1));
    expect(find.byKey(_dialog), findsOneWidget);
    expect(find.byKey(_error), findsOneWidget);
    expect(find.text('该证件号码已被其他员工使用'), findsOneWidget);
    expect(find.text('保存证件信息失败，请稍后重试'), findsNothing);
    expect(results.values, isEmpty);
    expect(
      tester.widget<FilledButton>(find.byKey(_save)).onPressed,
      isNotNull,
      reason: '失败后可以改了再提交',
    );
  });

  testWidgets('保存中锁住按钮，成功后先清忙标志再关弹窗', (tester) async {
    final pending = Completer<void>();
    final repository = _IdentityRepository(pending: pending);
    final results = await _open(tester, repository, profile: _profile());

    await tester.enterText(find.byKey(_number), '11010519491231002X');
    await tester.tap(find.byKey(_save));
    await tester.pump();

    expect(find.byType(UtenBusyOverlay), findsOneWidget);
    expect(find.text('保存中'), findsWidgets);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);

    pending.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(_dialog), findsNothing);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(results.values, [true]);
  });
}
