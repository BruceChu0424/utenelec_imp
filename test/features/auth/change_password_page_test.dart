import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/auth/pages/change_password_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final forced in [false, true]) {
    final mode = forced ? '首次设置' : '普通修改';
    for (final scenario in [
      (label: '单字符数字密码', password: '1'),
      (label: '超过 128 位的纯字母密码', password: 'x' * 129),
      (label: '首尾空格保留', password: '  密码  '),
    ]) {
      testWidgets('$mode：${scenario.label}通过表单并原样提交', (tester) async {
        final session = _RecordingSessionNotifier(forced: forced);
        await _openPage(tester, session, forced: forced);

        expect(
          tester
              .widget<Text>(find.byKey(const Key('change-password-rule')))
              .data,
          '密码不能为空',
        );
        await _fillForm(
          tester,
          oldPassword: ' old password ',
          newPassword: scenario.password,
          confirmation: scenario.password,
        );
        await _submit(tester);

        expect(session.submissions, [
          (oldPassword: ' old password ', newPassword: scenario.password),
        ]);
        expect(find.byType(ChangePasswordPage), findsNothing);
        expect(
          find.text(forced ? 'dashboard-home' : 'settings-home'),
          findsOneWidget,
        );
      });
    }

    testWidgets('$mode：各密码字段为空或全为空白时不提交', (tester) async {
      final session = _RecordingSessionNotifier(forced: forced);
      await _openPage(tester, session, forced: forced);

      for (final invalid in ['', '   ']) {
        for (final field in ['原密码', '新密码', '确认新密码']) {
          await _fillForm(
            tester,
            oldPassword: field == '原密码' ? invalid : 'old',
            newPassword: field == '新密码' ? invalid : '1',
            confirmation: field == '确认新密码' ? invalid : '1',
          );
          await _submit(tester);

          expect(session.submissions, isEmpty);
          expect(find.byType(ChangePasswordPage), findsOneWidget);
          final state = tester.state<FormFieldState<String>>(_field(field));
          expect(state.errorText, contains('不能为空'));
        }
      }
    });

    testWidgets('$mode：确认密码按原始内容比对，不忽略首尾空格', (tester) async {
      final session = _RecordingSessionNotifier(forced: forced);
      await _openPage(tester, session, forced: forced);
      await _fillForm(
        tester,
        oldPassword: 'old',
        newPassword: '1',
        confirmation: '1 ',
      );
      await _submit(tester);

      expect(session.submissions, isEmpty);
      expect(find.text('两次输入的新密码不一致'), findsOneWidget);
      expect(find.byType(ChangePasswordPage), findsOneWidget);
    });
  }
}

Finder _field(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is UtenInput && widget.label == label,
  ),
  matching: find.byType(TextFormField),
);

Future<void> _fillForm(
  WidgetTester tester, {
  required String oldPassword,
  required String newPassword,
  required String confirmation,
}) async {
  await tester.enterText(_field('原密码'), oldPassword);
  await tester.enterText(_field('新密码'), newPassword);
  await tester.enterText(_field('确认新密码'), confirmation);
}

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.text('确认'));
  await tester.tap(find.text('确认'));
  await tester.pumpAndSettle();
}

Future<void> _openPage(
  WidgetTester tester,
  _RecordingSessionNotifier session, {
  required bool forced,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: forced ? RouteName.changePassword : '/settings',
    routes: [
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: Text('settings-home')),
      ),
      GoRoute(
        path: RouteName.dashboard,
        builder: (_, _) => const Scaffold(body: Text('dashboard-home')),
      ),
      GoRoute(
        path: RouteName.changePassword,
        builder: (_, _) => ChangePasswordPage(forced: forced),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(() => session),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (!forced) {
    router.push<void>(RouteName.changePassword);
    await tester.pumpAndSettle();
  }
}

class _RecordingSessionNotifier extends SessionNotifier {
  _RecordingSessionNotifier({required this.forced});

  final bool forced;
  final submissions = <({String oldPassword, String newPassword})>[];

  @override
  SessionState build() => SessionState(
    status: forced ? AuthStatus.mustChangePassword : AuthStatus.authenticated,
  );

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    submissions.add((oldPassword: oldPassword, newPassword: newPassword));
    state = const SessionState(status: AuthStatus.authenticated);
  }
}
