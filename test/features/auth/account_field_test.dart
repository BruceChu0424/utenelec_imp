import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/account_history_store.dart';

class _History extends AccountHistoryStore {
  _History([List<String>? accounts])
    : accounts = List.of(accounts ?? ['recent-account', 'older-account']),
      super(SecureStorage(const FlutterSecureStorage()));
  final List<String> accounts;

  @override
  Future<List<String>> getAll() async => List.of(accounts);

  @override
  Future<void> remove(String account) async => accounts.remove(account);

  @override
  Future<void> clear() async => accounts.clear();
}

Future<void> _mount(
  WidgetTester tester, {
  required _History history,
  required TextEditingController controller,
  required FocusNode passwordFocus,
  required VoidCallback onLogin,
  bool openOnMount = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [accountHistoryProvider.overrideWithValue(history)],
      child: MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 320,
              child: Column(
                children: [
                  AccountField(controller: controller, hint: '账号'),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('password'),
                    focusNode: passwordFocus,
                    decoration: const InputDecoration(labelText: '密码'),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: onLogin, child: const Text('登录')),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (openOnMount) {
    await tester.tap(find.byType(AccountField));
    await tester.pumpAndSettle();
    expect(find.text('older-account'), findsOneWidget);
  }
}

void main() {
  for (final scenario in [
    (size: const Size(1222, 736), zoom: 1.0, dark: false),
    (size: const Size(1222, 736), zoom: .8, dark: false),
    (size: const Size(460, 720), zoom: 1.5, dark: true),
  ]) {
    testWidgets('真实登录页 ${scenario.size} ${scenario.zoom} 缩放可鼠标直点历史账号', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
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
            apiBaseUrlProvider.overrideWithValue(
              'https://login-test.example/api',
            ),
            platformBrandingSnapshotProvider.overrideWithValue(
              PlatformBranding.defaults,
            ),
          ],
          child: MaterialApp(
            theme: scenario.dark ? buildDarkTheme() : buildLightTheme(),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) =>
                UtenDisplayZoomBox(fontFactor: scenario.zoom, child: child!),
            home: const LoginPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AccountField),
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.down(tester.getCenter(field));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('older-account'), findsOneWidget);
      await tester.ensureVisible(find.text('older-account'));
      await tester.pumpAndSettle();
      await mouse.down(tester.getCenter(find.text('older-account')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.text('older-account'), findsOneWidget);
      await mouse.up();
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.text, 'older-account');
      expect(controller.selection.baseOffset, 'older-account'.length);
      expect(find.text('清除全部'), findsNothing);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    });
  }

  testWidgets('超出登录卡片的历史列表滚动后点击行空白选中，删除不误选账号', (tester) async {
    final history = _History([
      'recent-account',
      for (var i = 1; i <= 9; i++) 'older-account-$i',
    ]);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountHistoryProvider.overrideWithValue(history)],
        child: MaterialApp(
          home: Scaffold(
            body: SelectionArea(
              child: Center(
                child: SizedBox(
                  width: 320,
                  height: 100,
                  child: UtenCard(
                    child: AccountField(controller: controller, hint: '账号'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AccountField));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    expect(
      tester.getBottomRight(list).dy,
      greaterThan(tester.getBottomRight(find.byType(UtenCard)).dy),
    );
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('older-account-9'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('older-account-9'),
      matching: find.byType(InkWell),
    );
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('删除')));
    await tester.pumpAndSettle();
    expect(history.accounts, isNot(contains('older-account-9')));
    expect(controller.text, 'recent-account');
    final nextRow = find.ancestor(
      of: find.text('older-account-8'),
      matching: find.byType(InkWell),
    );
    final rowRect = tester.getRect(nextRow);
    // 账号文字右侧、删除按钮左侧的空白同样属于选中区域。
    final gesture = await tester.startGesture(
      Offset(rowRect.right - 70, rowRect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('older-account-8'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.text, 'older-account-8');
    expect(find.text('清除全部'), findsNothing);
  });

  testWidgets('鼠标从密码框打开历史后可直接点击账号整行', (tester) async {
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    await _mount(
      tester,
      history: _History(),
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () {},
      openOnMount: false,
    );
    passwordFocus.requestFocus();
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.down(tester.getCenter(find.byTooltip('历史账号')));
    await tester.pump(const Duration(milliseconds: 80));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('older-account'), findsOneWidget);
    await mouse.down(tester.getCenter(find.text('older-account')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('older-account'), findsOneWidget);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(controller.text, 'older-account');
    expect(find.text('清除全部'), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('历史打开时首次点击外部登录按钮即可提交并关闭浮层', (tester) async {
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    var submits = 0;
    await _mount(
      tester,
      history: _History(),
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () => submits++,
    );
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(submits, 1, reason: '关闭历史不应吞掉同一次登录点击');
    expect(find.text('older-account'), findsNothing);
    expect(controller.text, 'recent-account');
  });

  testWidgets('键盘或程序移焦到密码时关闭历史', (tester) async {
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    await _mount(
      tester,
      history: _History(),
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () {},
    );
    passwordFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(passwordFocus.hasFocus, isTrue);
    expect(find.text('older-account'), findsNothing);
  });

  testWidgets('候选按下跨帧再松手仍可选择，光标停在账号末尾', (tester) async {
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    await _mount(
      tester,
      history: _History(),
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () {},
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('older-account')),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('older-account'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.text, 'older-account');
    expect(controller.selection.baseOffset, 'older-account'.length);
    expect(find.text('清除全部'), findsNothing);
  });

  testWidgets('删除后刷新可见历史，清除全部关闭浮层且不改当前输入', (tester) async {
    final history = _History();
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    await _mount(
      tester,
      history: history,
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () {},
    );
    await tester.tap(find.byTooltip('删除').last);
    await tester.pumpAndSettle();
    expect(history.accounts, ['recent-account']);
    expect(find.text('older-account'), findsNothing);
    expect(find.text('清除全部'), findsOneWidget);
    await tester.tap(find.text('清除全部'));
    await tester.pumpAndSettle();
    expect(history.accounts, isEmpty);
    expect(find.text('清除全部'), findsNothing);
    expect(controller.text, 'recent-account');
  });
}
