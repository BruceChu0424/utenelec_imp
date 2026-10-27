import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/brand/uten_brand_mascot.dart';
import 'package:uten_imp/components/brand/uten_wordmark_logo.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/login_server_preparation.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/desktop_window_host.dart';

const _channel = MethodChannel('com.uten.imp/desktop_window');
typedef _Attempt = ({String account, String password, String? otpCode});

class _ChallengeSession extends SessionNotifier {
  final attempts = <_Attempt>[];

  @override
  SessionState build() => const SessionState();

  @override
  Future<void> login({
    required String account,
    required String password,
    String? otpCode,
    bool Function()? isCurrent,
  }) async {
    attempts.add((account: account, password: password, otpCode: otpCode));
    throw ApiException(
      otpCode == null ? 'MFA_REQUIRED' : 'MFA_INVALID',
      '请输入正确的动态验证码',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final size in [
      const Size(1000, 680),
      const Size(460, 720),
      const Size(1000, 440),
    ]) {
      for (final zoom in [1.0, 1.5, 2.0]) {
        testWidgets(
          '${platform.name} ${size.width.toInt()}x${size.height.toInt()} at ${zoom * 100}%: MFA remains usable in the login window',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            SharedPreferences.setMockInitialValues({});
            FlutterSecureStorage.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final controller = DesktopWindowController(enabled: true);
            addTearDown(controller.dispose);
            final calls = <MethodCall>[];
            messenger.setMockMethodCallHandler(_channel, (call) async {
              calls.add(call);
              return null;
            });
            addTearDown(
              () => messenger.setMockMethodCallHandler(_channel, null),
            );
            final session = _ChallengeSession();

            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  sharedPreferencesProvider.overrideWithValue(preferences),
                  sessionProvider.overrideWith(() => session),
                  loginServerPreparationProvider.overrideWithValue(() async {}),
                  desktopWindowControllerProvider.overrideWithValue(controller),
                  apiBaseUrlProvider.overrideWithValue(
                    'https://desktop-test.example/api',
                  ),
                  platformBrandingSnapshotProvider.overrideWithValue(
                    PlatformBranding.defaults,
                  ),
                ],
                child: MaterialApp(
                  theme: zoom == 1 ? buildLightTheme() : buildDarkTheme(),
                  locale: const Locale('zh'),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: DesktopWindowHost(
                    mode: DesktopWindowMode.login,
                    overlayControls: true,
                    child: UtenDisplayZoomBox(
                      fontFactor: zoom,
                      child: const LoginPage(),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.byType(AccountField), findsOneWidget);
            expect(find.byType(Form), findsOneWidget);
            expect(find.byType(UtenButton), findsOneWidget);
            if (size.width == 1000 && size.height >= 520 && zoom == 1) {
              final brandPanel = find.byKey(
                const Key('desktop-login-brand-panel'),
              );
              final formPanel = find.byKey(
                const Key('desktop-login-form-panel'),
              );
              expect(brandPanel, findsOneWidget);
              expect(formPanel, findsOneWidget);
              expect(
                find.descendant(
                  of: brandPanel,
                  matching: find.byType(UtenBrandMascot),
                ),
                findsOneWidget,
              );
              expect(
                find.descendant(
                  of: brandPanel,
                  matching: find.byType(UtenWordmarkLogo),
                ),
                findsOneWidget,
              );
              expect(
                find.descendant(of: brandPanel, matching: find.byType(Text)),
                findsNothing,
                reason:
                    'The left panel contains only the existing IP and logo.',
              );
              expect(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is Image &&
                      widget.image is AssetImage &&
                      (widget.image as AssetImage).assetName.contains(
                        'desktop_login_flow_v1.png',
                      ),
                ),
                findsNothing,
              );
              final brandBounds = tester.getRect(brandPanel);
              final formBounds = tester.getRect(formPanel);
              expect(brandBounds.right, lessThanOrEqualTo(formBounds.left));
              expect(brandBounds.top, lessThan(formBounds.bottom));
              expect(formBounds.top, lessThan(brandBounds.bottom));
              expect(
                tester.getCenter(_account).dx,
                greaterThan(size.width / 2),
              );
            } else {
              expect(
                find.byKey(const Key('desktop-login-brand-panel')),
                findsNothing,
                reason:
                    'Narrow, short or enlarged windows prioritize the usable form.',
              );
            }
            final close = tester.getRect(
              find.byKey(const Key('desktop-window-close')),
            );

            await _reveal(tester, _account);
            await tester.enterText(_account, 'desktop-worker');
            await _reveal(tester, _password);
            await tester.enterText(_password, ' exact password ');
            await _reveal(tester, find.byType(UtenButton));
            await tester.tap(find.byType(UtenButton));
            await tester.pumpAndSettle();

            expect(session.attempts, [
              (
                account: 'desktop-worker',
                password: ' exact password ',
                otpCode: null,
              ),
            ]);
            expect(_otp, findsOneWidget);
            await _reveal(tester, _otp);
            await tester.enterText(_otp, '123456');
            await _reveal(tester, find.byType(UtenButton));
            await tester.tap(find.byType(UtenButton));
            await tester.pumpAndSettle();

            expect(session.attempts.last.otpCode, '123456');
            expect(
              tester.widget<TextField>(_otp).controller!.text,
              isEmpty,
              reason: 'A rejected challenge clears the one-time code.',
            );
            final cancel = find.byKey(const Key('login-cancel-otp'));
            await _reveal(tester, cancel);
            await tester.tap(cancel);
            await tester.pumpAndSettle();
            expect(_otp, findsNothing);
            expect(session.attempts, hasLength(2));
            expect(
              tester.widget<TextField>(_account).controller!.text,
              'desktop-worker',
            );
            expect(
              tester.widget<TextField>(_password).controller!.text,
              ' exact password ',
            );
            await _reveal(tester, find.byType(UtenButton));
            expect(
              tester.getRect(find.byKey(const Key('desktop-window-close'))),
              close,
              reason: 'Scrolling the form leaves window controls accessible.',
            );
            expect(calls.map((call) => (call.method, call.arguments)), [
              ('setMode', 'login'),
            ]);
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant.only(platform),
        );
      }
    }
  }
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  // Finish the frame scheduled by enterText, including EditableText's caret
  // visibility request, before simulating the user's next scroll action.
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final bounds = tester.getRect(finder);
  final windowHeight =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  expect(bounds.center.dy, greaterThanOrEqualTo(36));
  expect(bounds.center.dy, lessThan(windowHeight));
  expect(tester.takeException(), isNull);
}
