import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/shell/widgets/uten_side_nav_rail.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/widgets/desktop_window_host.dart';

const _channel = MethodChannel('com.uten.imp/desktop_window');
const _headerKey = Key('desktop-window-header-surface');
final _captureKey = GlobalKey();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DesktopWindowController controller;
  late List<String> actions;
  late bool maximized;

  setUp(() {
    controller = DesktopWindowController(enabled: true);
    actions = [];
    maximized = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      actions.add(call.method);
      if (call.method == 'toggleMaximize') maximized = !maximized;
      if (call.method == 'getWindowState') return {'maximized': maximized};
      return null;
    });
  });

  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final dark in [false, true]) {
      testWidgets(
        '${platform.name}: ${dark ? 'dark' : 'light'} header follows the actual rail through zoom and collapse',
        (tester) async {
          final state = await _pump(tester, controller, dark: dark);
          final originalClose = tester.getRect(
            find.byKey(const Key('desktop-window-close')),
          );
          await tester.enterText(find.byType(TextField), '保留草稿');
          final editor = tester.state<EditableTextState>(
            find.byType(EditableText),
          );

          for (final zoom in [.85, 1.0, 1.3, 2.0]) {
            await tester.tap(find.byType(TextField));
            state.change(zoom: zoom);
            await tester.pumpAndSettle();
            _expectAligned(tester);
            expect(editor.widget.focusNode.hasFocus, isTrue);
            expect(
              tester.getRect(find.byKey(const Key('desktop-window-close'))),
              originalClose,
            );
            await tester.tap(find.byTooltip('收起导航栏'));
            await tester.pump();
            for (var frame = 0; frame < 5; frame++) {
              await tester.pump(const Duration(milliseconds: 40));
              _expectAligned(tester);
            }
            await tester.pumpAndSettle();
            _expectAligned(tester);
            expect(tester.state(find.byType(EditableText)), same(editor));
            expect(find.text('保留草稿'), findsOneWidget);
            await tester.tap(find.byTooltip('展开导航栏'));
            await tester.pumpAndSettle();
            _expectAligned(tester);
          }

          state.change(zoom: 1);
          await tester.pumpAndSettle();
          for (final size in [const Size(1040, 800), const Size(1600, 1000)]) {
            tester.view.physicalSize = size;
            await tester.pumpAndSettle();
            _expectAligned(tester);
          }
          if (const bool.fromEnvironment('UTEN_CHROME_CAPTURE')) {
            await _capture(
              tester,
              '${platform.name}-${dark ? 'dark' : 'light'}',
            );
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }

    testWidgets(
      '${platform.name}: covered routes hide the header while dialogs preserve it',
      (tester) async {
        await _pump(tester, controller);
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('独立页面')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(_headerKey), findsNothing);
        navigator.pop();
        await tester.pumpAndSettle();
        _expectAligned(tester);
        unawaited(
          showDialog<void>(
            context: tester.element(find.byType(NavigationRail)),
            builder: (_) => const AlertDialog(content: Text('普通弹窗')),
          ),
        );
        await tester.pumpAndSettle();
        _expectAligned(tester);
        navigator.pop();
        await tester.pumpAndSettle();
        _expectAligned(tester);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      '${platform.name}: header preserves native dragging and button actions',
      (tester) async {
        await _pump(tester, controller);
        actions.clear();
        // Start inside the new surface rather than the drag area's center.
        await tester.dragFrom(const Offset(40, 18), const Offset(60, 0));
        await tester.pumpAndSettle();
        expect(actions, ['beginDrag']);
        actions.clear();
        for (final action in ['minimize', 'maximize', 'close']) {
          await tester.tap(find.byKey(Key('desktop-window-$action')));
          await tester.pumpAndSettle();
        }
        expect(actions, [
          'minimize',
          'toggleMaximize',
          'getWindowState',
          'close',
        ]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      '${platform.name}: header is removed with the rail and disabled for login',
      (tester) async {
        final state = await _pump(tester, controller);
        _expectAligned(tester);
        state.change(railVisible: false);
        await tester.pumpAndSettle();
        expect(find.byKey(_headerKey), findsNothing);
        state.change(railVisible: true);
        await tester.pumpAndSettle();
        _expectAligned(tester);
        state.change(mode: DesktopWindowMode.login);
        await tester.pumpAndSettle();
        expect(find.byKey(_headerKey), findsNothing);
        state.change(mode: DesktopWindowMode.main);
        await tester.pumpAndSettle();
        _expectAligned(tester);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets('non-native shells do not extend their navigation surface', (
    tester,
  ) async {
    controller.dispose();
    controller = DesktopWindowController(enabled: false);
    await _pump(tester, controller);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(find.byKey(const Key('desktop-window-close')), findsNothing);
    expect(actions, isEmpty);
  });
}

void _expectAligned(WidgetTester tester) {
  final rail = tester.getRect(find.byType(NavigationRail));
  final header = tester.getRect(find.byKey(_headerKey));
  expect(header.left, closeTo(rail.left, .01));
  expect(header.width, closeTo(rail.width, .01));
  expect(header.top, 0);
  expect(header.height, DesktopWindowHost.controlsHeight);
  // The connection banner below the chrome still has its own entire row.
  expect(rail.top, greaterThan(DesktopWindowHost.controlsHeight));
  final decoration = tester
      .widget<DesktopWindowHeaderSurface>(
        find.byType(DesktopWindowHeaderSurface),
      )
      .decoration;
  final painted = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byKey(_headerKey),
      matching: find.byType(DecoratedBox),
    ),
  );
  expect(painted.decoration, decoration);
  final context = tester.element(find.byType(NavigationRail));
  final theme = Theme.of(context);
  expect(
    decoration.color,
    theme.navigationRailTheme.backgroundColor ?? theme.colorScheme.surface,
  );
}

Future<_WindowFixtureState> _pump(
  WidgetTester tester,
  DesktopWindowController controller, {
  bool dark = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1366, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        desktopWindowControllerProvider.overrideWithValue(controller),
        platformBrandingSnapshotProvider.overrideWithValue(
          PlatformBranding.defaults,
        ),
        apiBaseUrlProvider.overrideWithValue('https://chrome-test.invalid/api'),
      ],
      child: _WindowFixture(dark: dark),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_WindowFixtureState>(find.byType(_WindowFixture));
}

class _WindowFixture extends StatefulWidget {
  const _WindowFixture({required this.dark});
  final bool dark;

  @override
  State<_WindowFixture> createState() => _WindowFixtureState();
}

class _WindowFixtureState extends State<_WindowFixture> {
  double zoom = 1;
  bool extended = true;
  bool railVisible = true;
  DesktopWindowMode mode = DesktopWindowMode.main;

  void change({double? zoom, bool? railVisible, DesktopWindowMode? mode}) =>
      setState(() {
        this.zoom = zoom ?? this.zoom;
        this.railVisible = railVisible ?? this.railVisible;
        this.mode = mode ?? this.mode;
      });

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: widget.dark ? buildDarkTheme() : buildLightTheme(),
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    // Match production: host and its overlay are above the routed Navigator.
    builder: (context, child) => RepaintBoundary(
      key: _captureKey,
      child: DesktopWindowHost(
        mode: mode,
        child: UtenDisplayZoomBox(fontFactor: zoom, child: child!),
      ),
    ),
    home: Scaffold(
      body: Column(
        children: [
          const SizedBox(height: 32, child: Center(child: Text('连接状态提示'))),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (railVisible)
                  UtenSideNavRail(
                    selectedIndex: 0,
                    onTap: (_) {},
                    labels: const ['工作台', '通知', '我的', '设置'],
                    extended: extended,
                    onToggleExtended: () =>
                        setState(() => extended = !extended),
                  ),
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: TextField(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary =
        _captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory('output/desktop-window-chrome-20261028');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}
