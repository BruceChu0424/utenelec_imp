import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
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
        // 改密成功（含普通修改模式）统一回工作台。
        expect(find.text('dashboard-home'), findsOneWidget);
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

  testWidgets('服务端已改密但本机收尾失败：提示已修改并引导重新登录', (tester) async {
    final session = _CommitFailedSessionNotifier();
    await _openPage(tester, session, forced: false);
    await _fillForm(
      tester,
      oldPassword: 'old',
      newPassword: '1',
      confirmation: '1',
    );
    // 不走 _submit 的 pumpAndSettle：顶部通知 2.5s 自动消失，settle 会把它等没。
    await tester.ensureVisible(find.text('确认'));
    await tester.tap(find.text('确认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('密码已修改，请使用新密码重新登录'), findsOneWidget);
    expect(session.logouts, 1);
    // 不再显示与「未改成」混淆的兜底文案。
    expect(find.text('出错了，请稍后重试'), findsNothing);

    await tester.pumpAndSettle();
  });
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
  SessionNotifier session, {
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
        // 顶部通知宿主：appError/appSuccess 的卡片由它渲染。
        builder: (context, child) => Stack(
          children: [
            child!,
            const Align(
              alignment: Alignment.topCenter,
              child: AppNotificationHost(),
            ),
          ],
        ),
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

/// 模拟「服务端已接受改密，本机会话收尾失败」：changePassword 抛
/// PasswordChangeCommittedError，页面应提示已修改并调用 logout。
class _CommitFailedSessionNotifier extends SessionNotifier {
  var logouts = 0;

  @override
  SessionState build() => const SessionState(status: AuthStatus.authenticated);

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    throw const PasswordChangeCommittedError();
  }

  @override
  Future<void> logout() async {
    logouts++;
    state = const SessionState();
  }
}
