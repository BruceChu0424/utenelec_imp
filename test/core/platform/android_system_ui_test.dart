import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/platform/android_system_ui.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> platformCalls;
  setUp(() {
    platformCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call);
        return null;
      },
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  for (final dark in [false, true]) {
    testWidgets(
      'whole Android viewport keeps bar contrast and body behind SafeArea dark=$dark',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 800);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 40);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 40);
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        final theme = dark ? buildDarkTheme() : buildLightTheme();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundary,
              child: const UtenAndroidSystemUi(
                child: Scaffold(body: SafeArea(child: Text('页面内容'))),
              ),
            ),
          ),
        );
        await tester.pump();
        final layer = tester.binding.renderViews.single.debugLayer!;
        final overlay = layer.find<SystemUiOverlayStyle>(
          const Offset(200, 790),
        )!;
        expect(overlay.systemNavigationBarContrastEnforced, isFalse);
        expect(
          overlay.systemNavigationBarIconBrightness,
          dark ? Brightness.light : Brightness.dark,
        );
        expect(
          overlay.statusBarIconBrightness,
          dark ? Brightness.light : Brightness.dark,
        );
        expect(
          platformCalls
              .where(
                (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
              )
              .single
              .arguments,
          'SystemUiMode.edgeToEdge',
        );
        expect(
          MediaQuery.of(
            tester.element(find.byType(UtenAndroidSystemUi)),
          ).viewPadding.bottom,
          40,
        );
        final box =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await box.toImage();
          final data = (await image.toByteData())!;
          final pixel = (790 * image.width + 200) * 4;
          final color = Color.fromARGB(
            data.getUint8(pixel + 3),
            data.getUint8(pixel),
            data.getUint8(pixel + 1),
            data.getUint8(pixel + 2),
          );
          expect(color, theme.scaffoldBackgroundColor);
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'keyboard close restores visible bars after Android interval without losing focus or text',
    (tester) async {
      final controller = TextEditingController(text: '保留草稿');
      final focus = FocusNode();
      final mode = ValueNotifier(ThemeMode.dark);
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      addTearDown(mode.dispose);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ValueListenableBuilder<ThemeMode>(
          valueListenable: mode,
          builder: (_, value, _) => MaterialApp(
            theme: buildLightTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: value,
            home: UtenAndroidSystemUi(
              child: Scaffold(
                body: SafeArea(
                  child: TextField(controller: controller, focusNode: focus),
                ),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      int restores() => platformCalls
          .where(
            (call) => call.method == 'SystemChrome.restoreSystemUIOverlays',
          )
          .length;
      final before = restores();
      mode.value = ThemeMode.light;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 999));
      expect(restores(), before);
      await tester.pump(const Duration(milliseconds: 1));
      expect(restores(), before + 1);
      expect(focus.hasFocus, isTrue);
      expect(controller.text, '保留草稿');
      expect(
        MediaQuery.of(tester.element(find.byType(TextField))).viewInsets.bottom,
        0,
      );
      final overlay = tester.binding.renderViews.single.debugLayer!
          .find<SystemUiOverlayStyle>(const Offset(400, 590))!;
      expect(overlay.systemNavigationBarIconBrightness, Brightness.dark);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(restores(), before + 2);
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(restores(), before + 2);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'desktop keeps its own window behavior and emits no Android system commands',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: UtenAndroidSystemUi(child: Text('桌面'))),
      );
      expect(
        platformCalls.where(
          (call) =>
              call.method == 'SystemChrome.setEnabledSystemUIMode' ||
              call.method == 'SystemChrome.restoreSystemUIOverlays',
        ),
        isEmpty,
      );
      expect(find.text('桌面'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
