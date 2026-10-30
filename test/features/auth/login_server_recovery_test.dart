import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/login_server_preparation.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _recoveryAction = '恢复自动选择服务器';
const _recoveryHint = '登录异常或更换网络时使用；只会在此安装包内置的公司与云端地址之间自动选择。';

typedef _Attempt = ({String account, String password});

class _RejectedSession extends SessionNotifier {
  _RejectedSession(this.failure);

  final ApiException failure;
  final attempts = <_Attempt>[];

  @override
  SessionState build() => const SessionState();

  @override
  Future<void> login({
    required String account,
    required String password,
    bool Function()? isCurrent,
  }) async {
    attempts.add((account: account, password: password));
    throw failure;
  }
}

Finder get _account => find.descendant(
  of: find.byType(AccountField),
  matching: find.byType(TextField),
);
Finder get _password => find.byType(TextField).at(1);

void main() {
  final failures = [
    (
      name: 'cannot connect',
      error: NetworkException('SocketException: internal transport details'),
      feedback: '无法连接服务器，请检查网络连接后重试',
    ),
    (
      name: 'connection timeout',
      error: NetworkTimeoutException(),
      feedback: '连接服务器超时，请稍后重试',
    ),
    (
      name: 'bad credentials',
      error: ApiException('BAD_CREDENTIALS', 'Bad credentials'),
      feedback: '账号或密码错误，请重新输入',
    ),
    (
      name: 'invalid credentials',
      error: ApiException('INVALID_CREDENTIALS', 'Invalid credentials'),
      feedback: '账号或密码错误，请重新输入',
    ),
    (
      name: 'safe server feedback',
      error: ApiException('UNKNOWN', '登录服务暂不可用，请稍后再试'),
      feedback: '登录服务暂不可用，请稍后再试',
    ),
  ];
  for (final layout in [
    (platform: TargetPlatform.windows, size: const Size(1000, 680)),
    (platform: TargetPlatform.macOS, size: const Size(1000, 680)),
    (platform: TargetPlatform.android, size: const Size(390, 844)),
    (platform: TargetPlatform.android, size: const Size(1000, 680)),
  ]) {
    for (final failure in failures) {
      testWidgets(
        '${layout.platform.name} ${layout.size.width.toInt()}px: ${failure.name} reports the login result without server controls',
        (tester) async {
          final session = _RejectedSession(failure.error);
          await _open(tester, session, size: layout.size);
          _expectSimpleLogin();
          await _submit(tester);

          _expectSimpleLogin();
          final feedback = find.text(failure.feedback);
          expect(feedback, findsOneWidget);
          await tester.ensureVisible(feedback);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(session.attempts, [
            (account: 'desktop-worker', password: ' exact password '),
          ]);
          expect(
            tester.widget<TextField>(_password).controller!.text,
            ' exact password ',
          );
          expect(find.textContaining('SocketException'), findsNothing);
        },
        variant: TargetPlatformVariant.only(layout.platform),
      );
    }
  }

  testWidgets(
    'unauthorized remote access reports the same feedback as an unreachable server',
    (tester) async {
      final session = _RejectedSession(
        ApiException('REMOTE_ACCESS_DENIED', '该账号未授权外网(云端)访问'),
      );
      await _open(tester, session, size: const Size(1000, 680));
      _expectSimpleLogin();
      await _submit(tester);

      _expectSimpleLogin();
      expect(find.text('无法连接服务器，请检查网络连接后重试'), findsOneWidget);
      expect(find.textContaining('未授权'), findsNothing);
      expect(session.attempts, hasLength(1));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

void _expectSimpleLogin() {
  expect(find.byType(TextField), findsNWidgets(2));
  expect(find.text(_recoveryAction), findsNothing);
  expect(find.text(_recoveryHint), findsNothing);
  expect(find.textContaining('只会在此安装包内置的公司与云端地址之间自动选择'), findsNothing);
}

Future<void> _open(
  WidgetTester tester,
  _RejectedSession session, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(() => session),
        loginServerPreparationProvider.overrideWithValue(() async {}),
        apiBaseUrlProvider.overrideWithValue('https://login-test.example/api'),
        platformBrandingSnapshotProvider.overrideWithValue(
          PlatformBranding.defaults,
        ),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LoginPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(_account);
  await tester.enterText(_account, 'desktop-worker');
  await tester.pumpAndSettle();
  await tester.ensureVisible(_password);
  await tester.enterText(_password, ' exact password ');
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(UtenButton));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(UtenButton));
  await tester.pumpAndSettle();
}
