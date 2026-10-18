import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  _Session({this.code = 'MFA_REQUIRED'});
  final String code;
  final attempts = <String?>[];
  @override
  SessionState build() => const SessionState();
  @override
  Future<void> login({
    required String account,
    required String password,
    String? otpCode,
  }) async {
    attempts.add(otpCode);
    throw ApiException(
      otpCode == null ? code : 'MFA_INVALID',
      'Verification is required',
    );
  }
}

Future<void> _pump(WidgetTester tester, _Session session) async {
  tester.view.physicalSize = const Size(900, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        sessionProvider.overrideWith(() => session),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LoginPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).at(0), 'worker');
  await tester.enterText(find.byType(TextField).at(1), 'password');
}

void main() {
  testWidgets(
    'MFA challenge exposes OTP and only a new user action resubmits login',
    (tester) async {
      final session = _Session();
      await _pump(tester, session);
      await tester.tap(find.byType(UtenButton));
      await tester.pumpAndSettle();
      expect(session.attempts, [null]);
      expect(find.byKey(const Key('login-otp')), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('login-otp')),
          matching: find.byType(TextField),
        ),
        '001234',
      );
      await tester.tap(find.byType(UtenButton));
      await tester.pumpAndSettle();
      expect(session.attempts, [null, '001234']);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('login-otp')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        isEmpty,
      );
    },
  );
  testWidgets(
    'unenrolled remote account is directed to office setup without another request',
    (tester) async {
      final session = _Session(code: 'MFA_ENROLLMENT_REQUIRED');
      await _pump(tester, session);
      await tester.tap(find.byType(UtenButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('先在公司内网登录'), findsOneWidget);
      expect(session.attempts, [null]);
    },
  );
}
