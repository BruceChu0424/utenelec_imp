import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/platform_tables_host.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/account_history_store.dart';

class _History extends AccountHistoryStore {
  _History() : super(SecureStorage(const FlutterSecureStorage()));
  final accounts = [for (var i = 0; i < 10; i++) 'account-$i'];
  @override
  Future<List<String>> getAll() async => List.of(accounts);
}

void main() {
  for (final zoom in [0.8, 1.0, 1.5]) {
    testWidgets('真实登录页 $zoom 从输入框推算视觉第二行坐标点击图标文字与空白', (tester) async {
      tester.view.physicalSize = const Size(1920, 945);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountHistoryProvider.overrideWithValue(_History()),
            sharedPreferencesProvider.overrideWithValue(preferences),
            apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
            platformBrandingSnapshotProvider.overrideWithValue(
              PlatformBranding.defaults,
            ),
          ],
          child: MaterialApp(
            theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => UtenContextMenuPolicy(
              child: PlatformTablesHost(
                child: UtenDisplayZoomBox(
                  fontFactor: zoom,
                  child: UtenControlTheme(
                    child: UtenPageScrollbarHost(child: child!),
                  ),
                ),
              ),
            ),
            home: const LoginPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AccountField),
        matching: find.byType(TextField),
      );
      final controller = tester.widget<TextField>(field).controller!;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      for (final position in ['icon', 'text', 'blank']) {
        controller.text = 'account-0';
        await tester.tap(find.byTooltip('历史账号'));
        await tester.pumpAndSettle();
        expect(find.text('account-1'), findsOneWidget);
        final row = find.ancestor(
          of: find.text('account-1'),
          matching: find.byType(InkWell),
        );
        // Candidate global geometry is deliberately not consulted: a broken
        // follower transform could make getCenter(candidate) validate a false
        // hit location. Only the local row height comes from the menu.
        final rowHeight = tester.getSize(row).height;
        final fieldRect = tester.getRect(field);
        final x = switch (position) {
          'icon' => fieldRect.left + 21 * zoom,
          'text' => fieldRect.left + 64 * zoom,
          _ => fieldRect.right - 80 * zoom,
        };
        final visualPoint = Offset(
          x,
          fieldRect.bottom + (4 + 1.5 * rowHeight) * zoom,
        );
        await mouse.moveTo(visualPoint);
        await tester.pump(const Duration(milliseconds: 100));
        await mouse.down(visualPoint);
        await tester.pump(const Duration(milliseconds: 100));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(
          controller.text,
          'account-1',
          reason: '$position at $visualPoint',
        );
        expect(find.text('清除全部'), findsNothing);
      }
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });

    testWidgets('真实公共宿主 $zoom 鼠标悬停后按下跨帧并选取历史', (tester) async {
      tester.view.physicalSize = const Size(1920, 945);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController();
      final passwordFocus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(passwordFocus.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [accountHistoryProvider.overrideWithValue(_History())],
          child: MaterialApp(
            theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
            builder: (context, child) => UtenContextMenuPolicy(
              child: PlatformTablesHost(
                child: UtenDisplayZoomBox(
                  fontFactor: zoom,
                  child: UtenControlTheme(
                    child: UtenPageScrollbarHost(child: child!),
                  ),
                ),
              ),
            ),
            home: Scaffold(
              body: SelectionArea(
                child: Center(
                  child: SizedBox(
                    width: 376,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AccountField(controller: controller, hint: '账号'),
                        TextField(focusNode: passwordFocus),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      for (final account in ['account-1', 'account-3', 'account-0']) {
        await mouse.moveTo(tester.getCenter(find.byType(AccountField)));
        await mouse.down(tester.getCenter(find.byType(AccountField)));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(find.text(account), findsAtLeastNWidgets(1));
        final rowText = find.text(account).last;
        await mouse.moveTo(tester.getCenter(rowText));
        await tester.pump(const Duration(milliseconds: 500));
        await mouse.down(tester.getCenter(rowText));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('清除全部'), findsOneWidget);
        await mouse.up();
        await tester.pumpAndSettle();
        expect(controller.text, account);
        expect(find.text('清除全部'), findsNothing);
        passwordFocus.requestFocus();
        await tester.pumpAndSettle();
      }
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });
  }
}
