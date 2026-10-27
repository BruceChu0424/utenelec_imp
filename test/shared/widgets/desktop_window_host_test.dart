import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/shared/widgets/desktop_window_host.dart';

const _channel = MethodChannel('com.uten.imp/desktop_window');
const _closeKey = Key('desktop-window-close');
const _minimizeKey = Key('desktop-window-minimize');
const _dragKey = Key('desktop-window-drag');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DesktopWindowController controller;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    controller = DesktopWindowController(enabled: true);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    _desktopTestWidgets(
      '${platform.name}: login controls follow native ordering',
      (tester) async {
        await _pump(tester, controller);

        final close = tester.getCenter(find.byKey(_closeKey));
        final minimize = tester.getCenter(find.byKey(_minimizeKey));
        final drag = tester.getCenter(find.byKey(_dragKey));
        if (platform == TargetPlatform.macOS) {
          expect(close.dx, lessThan(minimize.dx));
          expect(minimize.dx, lessThan(drag.dx));
        } else {
          expect(drag.dx, lessThan(minimize.dx));
          expect(minimize.dx, lessThan(close.dx));
        }
        expect(find.byTooltip('Close'), findsOneWidget);
        expect(find.byTooltip('Minimize'), findsOneWidget);
        expect(calls.map((call) => (call.method, call.arguments)), [
          ('setMode', 'login'),
        ]);
      },
      platform: platform,
    );
  }

  _desktopTestWidgets('login controls invoke only their own native action', (
    tester,
  ) async {
    await _pump(tester, controller);
    calls.clear();

    await tester.tap(find.byKey(_minimizeKey), buttons: kSecondaryButton);
    await tester.tap(find.byKey(_closeKey), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await tester.tap(find.byKey(_minimizeKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_closeKey));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), ['minimize', 'close']);
  });

  _desktopTestWidgets(
    'drag strip starts native dragging only for the primary button',
    (tester) async {
      await _pump(tester, controller);
      calls.clear();

      await tester.tap(find.byKey(_dragKey), buttons: kSecondaryButton);
      await tester.tap(
        find.byKey(_dragKey),
        buttons: kPrimaryButton | kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);

      await tester.tap(find.byKey(_dragKey));
      await tester.pumpAndSettle();
      expect(calls.map((call) => call.method), ['beginDrag']);
    },
  );

  _desktopTestWidgets(
    'ordinary login pages reserve space below the native controls',
    (tester) async {
      await _pump(tester, controller);

      expect(
        tester.getTopLeft(find.byType(_DraftEditor)),
        const Offset(0, DesktopWindowHost.controlsHeight),
      );
      expect(tester.getTopLeft(find.byKey(_closeKey)).dy, 0);
      expect(tester.getTopLeft(find.byKey(_dragKey)).dy, 0);
    },
  );

  _desktopTestWidgets(
    'full bleed login keeps controls above the content without remounting it',
    (tester) async {
      await _pump(tester, controller, overlayControls: true);
      final editor = tester.state<_DraftEditorState>(find.byType(_DraftEditor));
      expect(tester.getTopLeft(find.byType(_DraftEditor)), Offset.zero);
      expect(find.byKey(_closeKey), findsOneWidget);
      expect(find.byKey(_dragKey), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '保留未提交输入');

      await _pump(tester, controller);
      expect(tester.state(find.byType(_DraftEditor)), same(editor));
      expect(editor.text.text, '保留未提交输入');
      expect(editor.focus.hasFocus, isTrue);
      expect(
        tester.getTopLeft(find.byType(_DraftEditor)),
        const Offset(0, DesktopWindowHost.controlsHeight),
      );
      expect(calls.map((call) => (call.method, call.arguments)), [
        ('setMode', 'login'),
      ]);
    },
  );

  _desktopTestWidgets(
    'main presentation leaves all content space to the application',
    (tester) async {
      await _pump(tester, controller, mode: DesktopWindowMode.main);

      expect(find.byKey(_closeKey), findsNothing);
      expect(find.byKey(_minimizeKey), findsNothing);
      expect(find.byKey(_dragKey), findsNothing);
      expect(tester.getTopLeft(find.byType(_DraftEditor)), Offset.zero);
      expect(calls.map((call) => (call.method, call.arguments)), [
        ('setMode', 'main'),
      ]);
    },
  );

  _desktopTestWidgets(
    'mode changes retain editor state, draft text and keyboard focus',
    (tester) async {
      await _pump(tester, controller);
      final editor = tester.state<_DraftEditorState>(find.byType(_DraftEditor));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '保留输入的账号');
      expect(editor.focus.hasFocus, isTrue);

      await _pump(tester, controller, mode: DesktopWindowMode.main);
      expect(tester.state(find.byType(_DraftEditor)), same(editor));
      expect(editor.text.text, '保留输入的账号');
      expect(editor.focus.hasFocus, isTrue);
      expect(find.byKey(_closeKey), findsNothing);

      await _pump(tester, controller);
      expect(tester.state(find.byType(_DraftEditor)), same(editor));
      expect(editor.text.text, '保留输入的账号');
      expect(editor.focus.hasFocus, isTrue);
      expect(find.byKey(_closeKey), findsOneWidget);
      await _pump(tester, controller);
      expect(calls.map((call) => (call.method, call.arguments)), [
        ('setMode', 'login'),
        ('setMode', 'main'),
        ('setMode', 'login'),
      ]);
    },
  );

  _desktopTestWidgets(
    'disabled native presentation adds no chrome or channel calls',
    (tester) async {
      controller.dispose();
      controller = DesktopWindowController();
      await _pump(tester, controller);
      await _pump(tester, controller, mode: DesktopWindowMode.main);

      expect(find.byKey(_closeKey), findsNothing);
      expect(find.byKey(_minimizeKey), findsNothing);
      expect(find.byKey(_dragKey), findsNothing);
      expect(tester.getTopLeft(find.byType(_DraftEditor)), Offset.zero);
      expect(calls, isEmpty);
    },
    platform: TargetPlatform.android,
  );

  _desktopTestWidgets(
    'personal display zoom does not shrink or enlarge window controls',
    (tester) async {
      await _pump(tester, controller);
      final originalClose = tester.getRect(find.byKey(_closeKey));
      final originalMinimize = tester.getRect(find.byKey(_minimizeKey));
      await _pump(tester, controller, zoom: 1.8);

      expect(tester.getRect(find.byKey(_closeKey)), originalClose);
      expect(tester.getRect(find.byKey(_minimizeKey)), originalMinimize);
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.macOS,
  );
}

void _desktopTestWidgets(
  String description,
  WidgetTesterCallback callback, {
  TargetPlatform platform = TargetPlatform.windows,
}) => testWidgets(
  description,
  callback,
  variant: TargetPlatformVariant.only(platform),
);

Future<void> _pump(
  WidgetTester tester,
  DesktopWindowController controller, {
  DesktopWindowMode mode = DesktopWindowMode.login,
  double zoom = 1,
  bool overlayControls = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        desktopWindowControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp(
        home: DesktopWindowHost(
          mode: mode,
          overlayControls: overlayControls,
          child: UtenDisplayZoomBox(
            fontFactor: zoom,
            child: const _DraftEditor(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _DraftEditor extends StatefulWidget {
  const _DraftEditor();

  @override
  State<_DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<_DraftEditor> {
  final text = TextEditingController();
  final focus = FocusNode();

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.only(top: 48),
      child: TextField(controller: text, focusNode: focus),
    ),
  );
}
