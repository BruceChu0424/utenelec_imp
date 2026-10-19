import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _remoteHint = '当前为外网登录，请输入验证器中的 6 位动态验证码';
const _serverA = 'https://office-a.example/api';
const _serverB = 'https://office-b.example/api';
final _server = StateProvider<String>((ref) => _serverA);

typedef _Attempt = ({String account, String password, String? otpCode});

class _Session extends SessionNotifier {
  final attempts = <_Attempt>[];
  Future<void> Function(_Attempt)? response;

  @override
  SessionState build() => const SessionState();

  @override
  Future<void> login({
    required String account,
    required String password,
    String? otpCode,
  }) async {
    final attempt = (account: account, password: password, otpCode: otpCode);
    attempts.add(attempt);
    final currentResponse = response;
    if (currentResponse != null) return currentResponse(attempt);
    throw ApiException(
      otpCode == null ? 'MFA_REQUIRED' : 'MFA_INVALID',
      'Verification is required',
    );
  }
}

Finder get _account => find.descendant(
  of: find.byType(AccountField),
  matching: find.byType(TextField),
);
Finder get _password => find.byType(TextField).at(1);
Finder get _otp => find.descendant(
  of: find.byKey(const Key('login-otp')),
  matching: find.byType(TextField),
);
Finder get _cancel => find.byKey(const Key('login-cancel-otp'));

String _text(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Session session, {
  Size size = const Size(900, 1100),
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/login',
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(
        path: RouteName.dashboard,
        builder: (_, _) => const Scaffold(body: Text('dashboard-home')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        sessionProvider.overrideWith(() => session),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(_account, 'worker');
  await tester.enterText(_password, 'password');
  return ProviderScope.containerOf(tester.element(find.byType(LoginPage)));
}

Future<void> _submit(WidgetTester tester, {bool settle = true}) async {
  await tester.ensureVisible(find.byType(UtenButton));
  await tester.tap(find.byType(UtenButton));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  for (final layout in [
    (name: 'compact', size: const Size(390, 844), dark: false),
    (name: 'medium', size: const Size(800, 1000), dark: false),
    (name: 'wide', size: const Size(1440, 1000), dark: false),
    (name: 'compact dark', size: const Size(390, 844), dark: true),
  ]) {
    testWidgets(
      '${layout.name}: only a server challenge reveals OTP and cancel restores password login',
      (tester) async {
        final session = _Session();
        await _pump(tester, session, size: layout.size, dark: layout.dark);

        expect(find.byType(TextField), findsNWidgets(2));
        expect(find.byKey(const Key('login-show-otp')), findsNothing);
        expect(_otp, findsNothing);
        expect(_cancel, findsNothing);
        await _submit(tester);

        expect(session.attempts.map((attempt) => attempt.otpCode), [null]);
        expect(_otp, findsOneWidget);
        expect(find.text(_remoteHint), findsOneWidget);
        expect(find.text('返回账号密码登录'), findsOneWidget);
        await tester.enterText(_otp, '001234');
        await tester.ensureVisible(_cancel);
        await tester.pumpAndSettle();
        expect(_cancel.hitTestable(), findsOneWidget);
        await tester.tap(_cancel);
        await tester.pumpAndSettle();

        expect(_otp, findsNothing);
        expect(_cancel, findsNothing);
        expect(find.text(_remoteHint), findsNothing);
        expect(_text(tester, _account), 'worker');
        expect(_text(tester, _password), 'password');
        expect(session.attempts, hasLength(1));

        // Returning to the password form does not bypass the server challenge.
        await _submit(tester);
        expect(session.attempts.map((attempt) => attempt.otpCode), [
          null,
          null,
        ]);
        expect(_text(tester, _otp), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('office login succeeds with only account and password', (
    tester,
  ) async {
    final session = _Session()..response = (_) async {};
    await _pump(tester, session);
    await _submit(tester);

    expect(session.attempts, [
      (account: 'worker', password: 'password', otpCode: null),
    ]);
    expect(find.text('dashboard-home'), findsOneWidget);
    expect(_otp, findsNothing);
  });

  testWidgets('returning to office on the same server allows password login', (
    tester,
  ) async {
    final session = _Session();
    await _pump(tester, session);
    await _submit(tester);
    await tester.enterText(_otp, '001234');
    await tester.ensureVisible(_cancel);
    await tester.tap(_cancel);
    await tester.pumpAndSettle();
    session.response = (_) async {};
    await _submit(tester);

    expect(session.attempts.map((attempt) => attempt.otpCode), [null, null]);
    expect(find.text('dashboard-home'), findsOneWidget);
  });

  testWidgets(
    'remote login waits for an explicit second submit with the code',
    (tester) async {
      final session = _Session()
        ..response = (attempt) async {
          if (attempt.otpCode == null) {
            throw ApiException('MFA_REQUIRED', 'Verification is required');
          }
        };
      await _pump(tester, session);
      await _submit(tester);
      expect(session.attempts, hasLength(1));
      expect(find.text('dashboard-home'), findsNothing);

      await tester.enterText(_otp, '001234');
      await tester.pumpAndSettle();
      expect(session.attempts, hasLength(1));
      await _submit(tester);

      expect(session.attempts, [
        (account: 'worker', password: 'password', otpCode: null),
        (account: 'worker', password: 'password', otpCode: '001234'),
      ]);
      expect(find.text('dashboard-home'), findsOneWidget);
    },
  );

  testWidgets(
    'MFA_INVALID also reveals OTP when returned on the first attempt',
    (tester) async {
      final session = _Session()
        ..response = (_) async {
          throw ApiException('MFA_INVALID', 'Invalid code');
        };
      await _pump(tester, session);
      await _submit(tester);

      expect(_otp, findsOneWidget);
      expect(_text(tester, _otp), isEmpty);
      expect(find.text('验证码错误、过期或已使用，请输入新的验证码'), findsOneWidget);
      expect(session.attempts, hasLength(1));
    },
  );

  testWidgets(
    'unenrolled remote account sees office setup guidance without OTP',
    (tester) async {
      final session = _Session()
        ..response = (_) async {
          throw ApiException('MFA_ENROLLMENT_REQUIRED', 'Setup required');
        };
      await _pump(tester, session);
      await _submit(tester);

      expect(find.textContaining('先在公司内网登录'), findsOneWidget);
      expect(_otp, findsNothing);
      expect(_cancel, findsNothing);
      expect(session.attempts.map((attempt) => attempt.otpCode), [null]);
    },
  );

  testWidgets('empty and short challenge codes do not send another request', (
    tester,
  ) async {
    final session = _Session();
    await _pump(tester, session);
    await _submit(tester);

    for (final invalid in ['', '12345']) {
      await tester.enterText(_otp, invalid);
      await _submit(tester);
      expect(session.attempts, hasLength(1));
      final field = find.descendant(
        of: find.byKey(const Key('login-otp')),
        matching: find.byType(TextFormField),
      );
      expect(
        tester.state<FormFieldState<String>>(field).errorText,
        '请输入 6 位数字验证码',
      );
    }
  });

  testWidgets(
    'rejected OTP is cleared and a fresh code requires another action',
    (tester) async {
      final session = _Session();
      await _pump(tester, session);
      await _submit(tester);
      await tester.enterText(_otp, '001234');
      await _submit(tester);

      expect(_text(tester, _otp), isEmpty);
      expect(find.text('验证码错误、过期或已使用，请输入新的验证码'), findsOneWidget);
      expect(session.attempts.map((attempt) => attempt.otpCode), [
        null,
        '001234',
      ]);
      await _submit(tester);
      expect(session.attempts, hasLength(2));
      await tester.enterText(_otp, '005678');
      await _submit(tester);
      expect(session.attempts.map((attempt) => attempt.otpCode), [
        null,
        '001234',
        '005678',
      ]);
    },
  );

  for (final error in [
    ApiException('INVALID_CREDENTIALS', '账号或密码错误'),
    ApiException('MFA_ENROLLMENT_REQUIRED', 'Setup required'),
    ApiException('MFA_LOCKED', 'Too many attempts'),
    ApiException('MFA_UNAVAILABLE', 'Verification unavailable'),
    StateError('Connection interrupted'),
  ]) {
    testWidgets('${error.runtimeType}: $error closes an earlier challenge', (
      tester,
    ) async {
      final session = _Session();
      await _pump(tester, session);
      await _submit(tester);
      await tester.enterText(_otp, '001234');
      session.response = (_) async => throw error;
      await _submit(tester);

      expect(_otp, findsNothing);
      expect(_cancel, findsNothing);
      expect(session.attempts.map((attempt) => attempt.otpCode), [
        null,
        '001234',
      ]);
      session.response = null;
      await _submit(tester);
      expect(session.attempts.last.otpCode, isNull);
      expect(_text(tester, _otp), isEmpty);
    });
  }

  testWidgets(
    'cursor movement preserves OTP but changing the account clears it',
    (tester) async {
      final session = _Session();
      await _pump(tester, session);
      await _submit(tester);
      await tester.enterText(_otp, '001234');

      final controller = tester.widget<TextField>(_account).controller!;
      controller.selection = const TextSelection.collapsed(offset: 1);
      await tester.pumpAndSettle();
      expect(_text(tester, _otp), '001234');
      expect(find.text(_remoteHint), findsOneWidget);

      await tester.enterText(_account, 'another-worker');
      await tester.pumpAndSettle();
      expect(_otp, findsNothing);
      expect(find.text(_remoteHint), findsNothing);
      expect(session.attempts, hasLength(1));
      await _submit(tester);
      expect(session.attempts.last, (
        account: 'another-worker',
        password: 'password',
        otpCode: null,
      ));
      expect(_text(tester, _otp), isEmpty);
    },
  );

  testWidgets('switching servers clears the challenge without sending a code', (
    tester,
  ) async {
    final session = _Session();
    final container = await _pump(tester, session);
    await _submit(tester);
    await tester.enterText(_otp, '001234');

    container.read(_server.notifier).state = _serverB;
    await tester.pumpAndSettle();
    expect(_otp, findsNothing);
    expect(find.text(_remoteHint), findsNothing);
    expect(session.attempts, hasLength(1));
    await _submit(tester);
    expect(session.attempts.last.otpCode, isNull);
    expect(_text(tester, _otp), isEmpty);
  });

  for (final boundary in ['account', 'server']) {
    for (final switchBack in [false, true]) {
      testWidgets(
        'late challenge is ignored after $boundary changes${switchBack ? ' A-B-A' : ''}',
        (tester) async {
          final pending = Completer<void>();
          final session = _Session()..response = (_) => pending.future;
          final container = await _pump(tester, session);
          await _submit(tester, settle: false);
          expect(session.attempts, hasLength(1));

          if (boundary == 'account') {
            await tester.enterText(_account, 'another-worker');
            await tester.pump();
            if (switchBack) await tester.enterText(_account, 'worker');
          } else {
            container.read(_server.notifier).state = _serverB;
            await tester.pump();
            if (switchBack) container.read(_server.notifier).state = _serverA;
          }
          await tester.pump();
          pending.completeError(
            ApiException('MFA_REQUIRED', 'Verification is required'),
          );
          await tester.pumpAndSettle();

          expect(_otp, findsNothing);
          expect(_cancel, findsNothing);
          expect(find.text(_remoteHint), findsNothing);
          expect(session.attempts, hasLength(1));
          session.response = null;
          await _submit(tester);
          expect(session.attempts, hasLength(2));
          expect(session.attempts.last.otpCode, isNull);
          expect(_text(tester, _otp), isEmpty);
        },
      );
    }
  }
}
