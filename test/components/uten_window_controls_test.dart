import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

const _closeKey = ValueKey('group-close');
const _minimizeKey = ValueKey('group-minimize');
const _expandKey = ValueKey('group-expand');

void main() {
  for (final dark in [false, true]) {
    for (final mainWindow in [false, true]) {
      final mode = mainWindow ? 'main' : 'login';
      testWidgets(
        '$mode native hover and focus follow the lowered glyph dark=$dark',
        (tester) async {
          final capture = GlobalKey();
          var closed = 0;
          await tester.runAsync(() async {
            final font = FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
            await font.load();
          });
          await _pump(
            tester,
            RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: dark ? const Color(0xff202020) : Colors.white,
                child: UtenWindowControls(
                  native: true,
                  onClose: () => closed++,
                  onMinimize: () {},
                  onExpand: () {},
                  showMinimize: true,
                  showExpand: mainWindow,
                  closeButtonKey: _closeKey,
                  minimizeButtonKey: _minimizeKey,
                  expandButtonKey: _expandKey,
                ),
              ),
            ),
            dark: dark,
          );
          await tester.pumpAndSettle();
          final target = tester.getRect(find.byKey(_closeKey));
          final glyph = _circle(tester, _closeKey);
          final boundary = tester.getRect(find.byKey(capture));
          final center = glyph.center - boundary.topLeft;
          final before = await _pixels(tester, capture);
          final mouse = await tester.createGesture(
            kind: ui.PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(glyph.center);
          await tester.pumpAndSettle();
          final hovered = await _pixels(
            tester,
            capture,
            captureName: '$mode-${dark ? 'dark' : 'light'}-hover',
          );
          _expectFeedbackCentered(before, hovered, center);
          expect(tester.getRect(find.byKey(_closeKey)), target);
          expect(target.size, const Size(30, 36));
          expect(glyph.top - target.top, 11);
          await mouse.removePointer();
          await tester.pumpAndSettle();

          for (var index = 0; index < (mainWindow ? 3 : 2); index++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          }
          await tester.pumpAndSettle();
          final focused = await _pixels(tester, capture);
          _expectFeedbackCentered(before, focused, center);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(closed, 1);
          expect(tester.getRect(find.byKey(_closeKey)), target);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'expand then close stay adjacent without a hidden minimize slot',
    (tester) async {
      final calls = <String>[];
      await _pump(
        tester,
        UtenWindowControls(
          onClose: () => calls.add('close'),
          onExpand: () => calls.add('expand'),
          showExpand: true,
          closeButtonKey: _closeKey,
          minimizeButtonKey: _minimizeKey,
          expandButtonKey: _expandKey,
        ),
      );

      expect(find.byKey(_minimizeKey), findsNothing);
      expect(find.byIcon(Icons.remove_rounded), findsNothing);
      expect(find.byType(IconButton), findsNWidgets(2));
      expect(
        tester.getSize(find.byType(UtenWindowControls)),
        const Size(72, 36),
      );
      final close = tester.getRect(find.byKey(_closeKey));
      final expand = tester.getRect(find.byKey(_expandKey));
      expect(expand.right, close.left);
      expect(
        close.right,
        tester.getRect(find.byType(UtenWindowControls)).right,
      );
      expect(
        _circle(tester, _closeKey).left - _circle(tester, _expandKey).right,
        8,
      );
      expect(_color(tester, _closeKey), UtenColors.error);
      expect(_color(tester, _expandKey), UtenColors.success);

      await tester.tap(find.byKey(_closeKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_expandKey));
      await tester.pumpAndSettle();
      expect(calls, ['close', 'expand']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in TargetPlatform.values) {
    testWidgets(
      '${platform.name} keeps minimize expand close adjacent with close rightmost',
      (tester) async {
        await _pump(
          tester,
          UtenWindowControls(
            onClose: () {},
            onMinimize: () {},
            onExpand: () {},
            showMinimize: true,
            showExpand: true,
            closeButtonKey: _closeKey,
            minimizeButtonKey: _minimizeKey,
            expandButtonKey: _expandKey,
          ),
          platform: platform,
        );

        final touch = [
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.fuchsia,
        ].contains(platform);
        final extent = touch ? 48.0 : 36.0;
        final close = tester.getRect(find.byKey(_closeKey));
        final minimize = tester.getRect(find.byKey(_minimizeKey));
        final expand = tester.getRect(find.byKey(_expandKey));
        expect(close.size, Size.square(extent));
        expect(minimize.size, close.size);
        expect(expand.size, close.size);
        expect(minimize.right, expand.left);
        expect(expand.right, close.left);
        expect(
          close.right,
          tester.getRect(find.byType(UtenWindowControls)).right,
        );
        expect(close.center.dy, minimize.center.dy);
        expect(minimize.center.dy, expand.center.dy);
        expect(
          tester.getSize(find.byType(UtenWindowControls)),
          Size(extent * 3, extent),
        );
        expect(_color(tester, _closeKey), UtenColors.error);
        expect(_color(tester, _minimizeKey), UtenColors.warning);
        expect(_color(tester, _expandKey), UtenColors.success);
        if (!touch) {
          expect(
            _circle(tester, _closeKey).left - _circle(tester, _expandKey).right,
            8,
          );
          expect(
            _circle(tester, _expandKey).left -
                _circle(tester, _minimizeKey).right,
            8,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('native group retains 30 by 36 targets and 8dp visual gaps', (
    tester,
  ) async {
    await _pump(
      tester,
      UtenWindowControls(
        onClose: () {},
        onMinimize: () {},
        onExpand: () {},
        showMinimize: true,
        showExpand: true,
        native: true,
        closeButtonKey: _closeKey,
        minimizeButtonKey: _minimizeKey,
        expandButtonKey: _expandKey,
      ),
    );
    expect(tester.getSize(find.byType(UtenWindowControls)), const Size(90, 36));
    for (final key in [_closeKey, _minimizeKey, _expandKey]) {
      final target = tester.getRect(find.byKey(key));
      final circle = _circle(tester, key);
      expect(target.size, const Size(30, 36));
      expect(circle.size, const Size.square(22));
      // Maximized windows are flush with the physical screen top; the glyph
      // keeps 11px of clearance there while the hit target spans the strip.
      expect(circle.top - target.top, 11);
      expect(target.bottom - circle.bottom, 3);
      expect(circle.center.dx, target.center.dx);
    }
    expect(
      _circle(tester, _closeKey).left - _circle(tester, _expandKey).right,
      8,
    );
    expect(
      _circle(tester, _expandKey).left - _circle(tester, _minimizeKey).right,
      8,
    );
  });

  testWidgets(
    'visible disabled controls preserve callbacks keys and tooltips',
    (tester) async {
      final calls = <String>[];
      await _pump(
        tester,
        UtenWindowControls(
          onClose: null,
          onMinimize: () => calls.add('minimize'),
          onExpand: () => calls.add('expand'),
          showMinimize: true,
          showExpand: true,
          expanded: true,
          closeTooltip: 'Dismiss this window',
          minimizeTooltip: 'Keep for later',
          expandTooltip: 'Restore this window',
          closeButtonKey: _closeKey,
          minimizeButtonKey: _minimizeKey,
          expandButtonKey: _expandKey,
        ),
      );
      expect(find.byTooltip('Dismiss this window'), findsOneWidget);
      expect(find.byTooltip('Keep for later'), findsOneWidget);
      expect(find.byTooltip('Restore this window'), findsOneWidget);
      final closeButton = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(_closeKey),
          matching: find.byType(IconButton),
        ),
      );
      expect(closeButton.onPressed, isNull);
      expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
      await tester.tap(find.byKey(_closeKey));
      await tester.tap(find.byKey(_minimizeKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_expandKey));
      await tester.pumpAndSettle();
      expect(calls, ['minimize', 'expand']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('default group creates only close and no empty action slots', (
    tester,
  ) async {
    await _pump(
      tester,
      UtenWindowControls(
        onClose: () {},
        onMinimize: () {},
        onExpand: () {},
        closeButtonKey: _closeKey,
        minimizeButtonKey: _minimizeKey,
        expandButtonKey: _expandKey,
      ),
    );
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byKey(_closeKey), findsOneWidget);
    expect(find.byKey(_minimizeKey), findsNothing);
    expect(find.byKey(_expandKey), findsNothing);
    expect(tester.getSize(find.byType(UtenWindowControls)), const Size(36, 36));
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget controls, {
  TargetPlatform platform = TargetPlatform.windows,
  bool dark = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(
      platform: platform,
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    home: Scaffold(body: Center(child: controls)),
  ),
);

typedef _ControlPixels = ({Uint8List data, int width, int height});

Future<_ControlPixels> _pixels(
  WidgetTester tester,
  GlobalKey key, {
  String? captureName,
}) async => (await tester.runAsync(() async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  try {
    final data = (await image.toByteData())!;
    if (captureName != null &&
        const bool.fromEnvironment('UTEN_WINDOW_HOVER_CAPTURE')) {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final directory = Directory('build/window-control-hover')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$captureName.png',
      ).writeAsBytes(png.buffer.asUint8List());
    }
    return (
      data: data.buffer.asUint8List(),
      width: image.width,
      height: image.height,
    );
  } finally {
    image.dispose();
  }
}))!;

void _expectFeedbackCentered(
  _ControlPixels before,
  _ControlPixels after,
  Offset glyphCenter,
) {
  expect(after.width, before.width);
  expect(after.height, before.height);
  var left = before.width, top = before.height, right = -1, bottom = -1;
  for (var y = 0; y < before.height; y++) {
    for (var x = 0; x < before.width; x++) {
      final offset = (y * before.width + x) * 4;
      var changed = false;
      for (var channel = 0; channel < 4; channel++) {
        changed |=
            before.data[offset + channel] != after.data[offset + channel];
      }
      if (!changed) continue;
      if (x < left) left = x;
      if (y < top) top = y;
      if (x > right) right = x;
      if (y > bottom) bottom = y;
    }
  }
  expect(
    right,
    greaterThanOrEqualTo(0),
    reason: 'Actual feedback must be painted',
  );
  final bounds = Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right + 1.0,
    bottom + 1.0,
  );
  expect(bounds.center.dx, closeTo(glyphCenter.dx, .5));
  expect(bounds.center.dy, closeTo(glyphCenter.dy, .5));
}

Rect _circle(WidgetTester tester, Key key) => tester.getRect(
  find.descendant(of: find.byKey(key), matching: find.byType(Container)),
);

Color? _color(WidgetTester tester, Key key) =>
    (tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(key),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration)
        .color;
