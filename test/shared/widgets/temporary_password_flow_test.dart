import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/features/admin/widgets/set_temporary_password_dialog.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/employee_reset_password_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/widgets/temporary_password_input.dart';

import '../../support/audit_screenshot_support.dart';

enum _Entry { admin, employee }

const _custom = ' 合成口令A7! ';
const _random = 'SYNTHETIC-RANDOM-20!';
const _capture = bool.fromEnvironment('UTEN_CAPTURE_TEMP_PASSWORD');

class _Session extends SessionNotifier {
  _Session(this.permissions);
  final List<String> permissions;
  @override
  SessionState build() => _state('synthetic-support');

  void switchUser() => state = _state('another-synthetic-support');

  SessionState _state(String id) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: id,
      code: 'SUPPORT-SAMPLE',
      name: '合成账号维护人员',
      permissions: permissions,
    ),
  );
}

class _Harness {
  final captureKey = GlobalKey();
  final requests = <RequestOptions>[];
  final results = <Object?>[];
  late _Session session;
  String? issuedOverride;
}

Finder _dialog(_Entry entry) => find.byKey(
  ValueKey(
    entry == _Entry.admin
        ? 'set-temporary-password-dialog'
        : 'employee-reset-password-dialog',
  ),
);

Finder _confirm(_Entry entry) => find.byKey(
  ValueKey(
    entry == _Entry.admin
        ? 'set-temporary-password-confirm'
        : 'employee-reset-password-confirm',
  ),
);

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

TemporaryPasswordInputController _controller(WidgetTester tester) => tester
    .widget<TemporaryPasswordInput>(find.byType(TemporaryPasswordInput))
    .controller;

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _selectManual(WidgetTester tester) async {
  final field = find.byType(TemporaryPasswordInput);
  final manual = find.descendant(of: field, matching: find.text('手动输入'));
  if (manual.evaluate().isNotEmpty) {
    await _tap(tester, manual);
  } else {
    await _tap(
      tester,
      find.descendant(of: field, matching: find.byType(OutlinedButton)),
    );
    await _tap(tester, find.text('手动输入').last);
  }
}

Future<void> _enterCustom(WidgetTester tester) async {
  await _selectManual(tester);
  await tester.enterText(_field('temporary-password-input'), _custom);
  await tester.enterText(_field('temporary-password-confirmation'), _custom);
  await tester.pumpAndSettle();
}

Future<_Harness> _open(
  WidgetTester tester,
  _Entry entry, {
  bool allowManual = true,
  bool dark = false,
  double scale = 1,
  Size size = const Size(1000, 1100),
  String? issuedOverride,
  List<String> permissions = const [Perm.accountSupport],
  bool expectDialog = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final harness = _Harness()..issuedOverride = issuedOverride;
  final dio = Dio(BaseOptions(baseUrl: 'https://synthetic.invalid/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        harness.requests.add(request);
        final body = request.data as Map<String, dynamic>?;
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: {
              'temporaryPassword':
                  harness.issuedOverride ??
                  body?['temporaryPassword'] ??
                  _random,
            },
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(
          () => harness.session = _Session(permissions),
        ),
        employeeRepositoryProvider.overrideWithValue(
          DioEmployeeRepository(api),
        ),
      ],
      child: RepaintBoundary(
        key: harness.captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: auditScreenshotTheme(
            dark ? buildDarkTheme() : buildLightTheme(),
          ),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final Object? result;
                  if (entry == _Entry.admin) {
                    result = await showSetTemporaryPasswordDialog(
                      context,
                      displayName: '合成目标账号',
                      loginAccount: 'synthetic-target',
                      allowManual: allowManual,
                    );
                  } else {
                    result = await showEmployeeResetPasswordDialog(
                      context,
                      employee: EmployeeProfile(
                        id: 'synthetic-employee',
                        code: 'SYN-0007',
                        fullName: '合成员工',
                        status: 'active',
                        accountStatus: 'active',
                        accountSupportAllowed: true,
                        passwordResetSupportAllowed: allowManual ? true : null,
                      ),
                    );
                  }
                  harness.results.add(result);
                },
                child: const Text('打开合成账号流程'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, find.text('打开合成账号流程'));
  expect(_dialog(entry), expectDialog ? findsOneWidget : findsNothing);
  return harness;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final data = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
    for (final family in ['NotoSansSC', 'Roboto']) {
      await (FontLoader(family)..addFont(Future.value(data))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final entry in _Entry.values) {
    testWidgets(
      'legacy endpoint keeps manual disabled and random available: ${entry.name}',
      (tester) async {
        final harness = await _open(tester, entry, allowManual: false);
        final modes = tester.widget<UtenSegmentRow<bool>>(
          find.byType(UtenSegmentRow<bool>),
        );
        expect(
          modes.segments.singleWhere((segment) => segment.value).enabled,
          isFalse,
        );
        modes.onSelectionChanged!({true});
        await tester.pumpAndSettle();
        expect(_controller(tester).manual, isFalse);
        expect(_field('temporary-password-input'), findsNothing);
        await _tap(tester, _confirm(entry));
        if (entry == _Entry.admin) {
          expect(
            (harness.results.single! as TemporaryPasswordChoice)
                .temporaryPassword,
            isNull,
          );
        } else {
          expect(harness.requests.single.data, isNull);
          expect(find.text(_random), findsOneWidget);
          await _tap(
            tester,
            find.byKey(const ValueKey('employee-reset-password-saved')),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'legacy endpoint rejects a retained manual choice: ${entry.name}',
      (tester) async {
        final harness = await _open(tester, entry, allowManual: false);
        final controller = _controller(tester);
        // The disabled presentation is not the command boundary. Reproduce a
        // retained/programmatic mode without changing server capability metadata.
        controller.selectManual(true);
        await tester.pumpAndSettle();
        await tester.enterText(_field('temporary-password-input'), _custom);
        await tester.enterText(
          _field('temporary-password-confirmation'),
          _custom,
        );
        await _tap(tester, _confirm(entry));
        expect(harness.requests, isEmpty);
        expect(harness.results, isEmpty);
        expect(_dialog(entry), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('cancel clears both input buffers: ${entry.name}', (
      tester,
    ) async {
      final harness = await _open(tester, entry);
      await _enterCustom(tester);
      final controller = _controller(tester);
      await _tap(tester, find.widgetWithText(TextButton, '取消'));
      expect(controller.password.text, isEmpty);
      expect(controller.confirmation.text, isEmpty);
      expect(harness.requests, isEmpty);
      expect(harness.results, [entry == _Entry.admin ? null : false]);
    });

    testWidgets(
      'switching operator during input erases retired buffers: ${entry.name}',
      (tester) async {
        final harness = await _open(tester, entry);
        await _enterCustom(tester);
        final controller = _controller(tester);
        harness.session.switchUser();
        await tester.pumpAndSettle();
        expect(controller.password.text, isEmpty);
        expect(controller.confirmation.text, isEmpty);
        expect(_dialog(entry), findsNothing);
        expect(harness.requests, isEmpty);
        expect(find.text(_custom), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final dark in [false, true]) {
      testWidgets(
        '375px large text manual confirm and cancel ${entry.name} dark=$dark',
        (tester) async {
          final harness = await _open(
            tester,
            entry,
            dark: dark,
            scale: 1.6,
            size: const Size(375, 900),
          );
          await _enterCustom(tester);
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          if (_capture) {
            await saveAuditScreenshot(
              tester,
              harness.captureKey,
              'temporary-password-${entry.name}-${dark ? 'dark' : 'light'}-375-manual',
            );
          }
          if (entry == _Entry.admin) {
            final warning = find.textContaining('切勿明文留存');
            await Scrollable.ensureVisible(
              tester.element(warning),
              alignment: 1,
            );
            await tester.pumpAndSettle();
            final viewport = find
                .ancestor(
                  of: warning,
                  matching: find.byType(SingleChildScrollView),
                )
                .first;
            expect(
              tester.getRect(warning).bottom,
              lessThanOrEqualTo(tester.getRect(viewport).bottom + .5),
            );
            if (_capture) {
              await saveAuditScreenshot(
                tester,
                harness.captureKey,
                'temporary-password-admin-${dark ? 'dark' : 'light'}-375-warning',
              );
            }
          }
          await _tap(tester, find.widgetWithText(TextButton, '取消'));
          expect(harness.requests, isEmpty);
          await _tap(tester, find.text('打开合成账号流程'));
          expect(_controller(tester).password.text, isEmpty);
          expect(_controller(tester).manual, isFalse);
          await _enterCustom(tester);
          tester.view.viewInsets = const FakeViewPadding(bottom: 240);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(_confirm(entry)).bottom,
            lessThanOrEqualTo(660),
          );
          await _tap(tester, _confirm(entry));
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          if (entry == _Entry.admin) {
            expect(
              (harness.results.last! as TemporaryPasswordChoice)
                  .temporaryPassword,
              _custom,
            );
          } else {
            expect(harness.requests.single.data, {
              'temporaryPassword': _custom,
            });
            expect(find.text(_custom), findsOneWidget);
            if (_capture) {
              await saveAuditScreenshot(
                tester,
                harness.captureKey,
                'temporary-password-employee-${dark ? 'dark' : 'light'}-375-receipt',
              );
            }
            await _tap(
              tester,
              find.byKey(const ValueKey('employee-reset-password-saved')),
            );
            expect(harness.results.last, isTrue);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'employee command requires actual account support even with a capable target',
    (tester) async {
      final harness = await _open(
        tester,
        _Entry.employee,
        permissions: const [Perm.authorizationManage],
        expectDialog: false,
      );
      expect(harness.requests, isEmpty);
      expect(harness.results, [false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'different manual receipt is uncertain and cannot be displayed or replayed',
    (tester) async {
      final harness = await _open(
        tester,
        _Entry.employee,
        issuedOverride: 'DIFFERENT-RECEIPT-ONLY',
      );
      await _enterCustom(tester);
      final controller = _controller(tester);
      final staleSubmit = tester
          .widget<FilledButton>(_confirm(_Entry.employee))
          .onPressed!;
      await _tap(tester, _confirm(_Entry.employee));
      expect(harness.requests, hasLength(1));
      expect(find.textContaining('设置结果暂时无法确认'), findsOneWidget);
      expect(find.text('DIFFERENT-RECEIPT-ONLY'), findsNothing);
      expect(controller.password.text, isEmpty);
      expect(controller.confirmation.text, isEmpty);
      expect(
        tester.widget<FilledButton>(_confirm(_Entry.employee)).onPressed,
        isNull,
      );
      staleSubmit();
      await tester.pumpAndSettle();
      expect(harness.requests, hasLength(1));
      await _tap(tester, find.text('关闭并刷新'));
      expect(harness.results.last, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
