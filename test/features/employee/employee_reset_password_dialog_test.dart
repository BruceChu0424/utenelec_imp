import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/employee_reset_password_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

const _dialog = ValueKey('employee-reset-password-dialog');
const _confirm = ValueKey('employee-reset-password-confirm');
const _cancel = ValueKey('employee-reset-password-cancel');
const _saved = ValueKey('employee-reset-password-saved');
const _temporaryPassword = 'T8!temporary-Employee2';
const _employee = EmployeeProfile(
  id: 'emp-7',
  code: 'UT0007',
  fullName: '赵六',
  phone: '13800138000',
  status: 'active',
  accountStatus: 'active',
);

class _ResetRepository extends Fake implements EmployeeRepository {
  final employeeIds = <String>[];
  Completer<String>? pending;
  ApiException? error;

  @override
  Future<String> resetPassword(String id) async {
    employeeIds.add(id);
    final failure = error;
    if (failure != null) throw failure;
    return pending?.future ?? _temporaryPassword;
  }
}

class _Session extends SessionNotifier {
  _Session(this.permissions);

  final List<String> permissions;

  @override
  SessionState build() => _state(permissions);

  void revokeAccountSupport() => state = _state(const []);

  SessionState _state(List<String> permissions) => SessionState(
    user: AppUser(
      id: 'hr-user',
      code: 'HR001',
      name: '人事',
      permissions: permissions,
    ),
  );
}

class _Results {
  final values = <bool?>[];
  late _Session session;
}

Future<_Results> _open(
  WidgetTester tester,
  _ResetRepository repository, {
  List<String> permissions = const [Perm.accountSupport],
}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final results = _Results();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeeRepositoryProvider.overrideWithValue(repository),
        sessionProvider.overrideWith(
          () => results.session = _Session(permissions),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                results.values.add(
                  await showEmployeeResetPasswordDialog(
                    context,
                    employee: _employee,
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
  // 建立打开弹窗时的人事会话与权限快照，以便测试打开后撤权。
  ProviderScope.containerOf(
    tester.element(find.byKey(_dialog)),
  ).read(currentPermissionsProvider);
  return results;
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);

  testWidgets('取消不调用重置接口，也不返回成功', (tester) async {
    final repository = _ResetRepository();
    final results = await _open(tester, repository);

    await tester.tap(find.byKey(_cancel));
    await tester.pumpAndSettle();

    expect(repository.employeeIds, isEmpty);
    expect(find.byKey(_dialog), findsNothing);
    expect(results.values, [false]);
  });

  testWidgets('正确员工收到临时密码，保存前不能返回或点遮罩丢失凭据', (tester) async {
    final repository = _ResetRepository();
    final results = await _open(tester, repository);

    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();

    expect(repository.employeeIds, ['emp-7']);
    expect(find.textContaining('赵六'), findsWidgets);
    expect(find.textContaining('UT0007'), findsWidgets);
    expect(find.text('一次性临时密码'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data == _temporaryPassword,
      ),
      findsOneWidget,
    );
    expect(find.byKey(_confirm), findsNothing);
    expect(find.byKey(_cancel), findsNothing);
    expect(results.values, isEmpty);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text(_temporaryPassword), findsOneWidget);
    expect(find.byKey(_dialog), findsOneWidget);
    expect(results.values, isEmpty);
    expect(repository.employeeIds, ['emp-7']);

    await tester.tap(find.byKey(_saved));
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsNothing);
    expect(results.values, [true]);
  });

  testWidgets('生成中防重复提交，取消和返回均不能关闭等待中的请求', (tester) async {
    final pending = Completer<String>();
    final repository = _ResetRepository()..pending = pending;
    final results = await _open(tester, repository);

    // 第二次点击发生在下一帧按钮禁用之前，仍应只有一次请求。
    await tester.tap(find.byKey(_confirm));
    await tester.tap(find.byKey(_confirm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(repository.employeeIds, ['emp-7']);
    expect(tester.widget<FilledButton>(find.byKey(_confirm)).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(_cancel)).onPressed, isNull);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(find.byKey(_dialog), findsOneWidget);
    expect(results.values, isEmpty);

    pending.complete(_temporaryPassword);
    await tester.pumpAndSettle();
    expect(find.text(_temporaryPassword), findsOneWidget);
    expect(repository.employeeIds, ['emp-7']);
  });

  testWidgets('服务端拒绝原话留在弹窗中，允许重试', (tester) async {
    final repository = _ResetRepository()
      ..error = ApiException('CONFLICT', '该员工账号已停用，不能修改密码');
    final results = await _open(tester, repository);

    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(find.text('该员工账号已停用，不能修改密码'), findsOneWidget);
    expect(find.byKey(_dialog), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(_confirm)).onPressed,
      isNotNull,
    );
    expect(results.values, isEmpty);

    repository.error = null;
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(repository.employeeIds, ['emp-7', 'emp-7']);
    expect(find.text(_temporaryPassword), findsOneWidget);
    expect(find.text('该员工账号已停用，不能修改密码'), findsNothing);
  });

  testWidgets('弹窗打开后撤销账号维护权限，提交重新校验且不发请求', (tester) async {
    final repository = _ResetRepository();
    final results = await _open(tester, repository);
    results.session.revokeAccountSupport();
    await tester.pump();

    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(repository.employeeIds, isEmpty);
    expect(find.byKey(_dialog), findsOneWidget);
    expect(find.textContaining('权限'), findsWidgets);
    expect(find.text(_temporaryPassword), findsNothing);
    expect(results.values, isEmpty);
  });

  testWidgets('复制按钮仅复制返回的临时密码', (tester) async {
    final clipboardWrites = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await _open(tester, _ResetRepository());
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();

    await tester.tap(find.text('复制密码'));
    await tester.pumpAndSettle();
    expect(clipboardWrites, [
      {'text': _temporaryPassword},
    ]);
    expect(find.byKey(_dialog), findsOneWidget);
  });
}
