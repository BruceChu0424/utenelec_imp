import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

const _closeKey = ValueKey('group-close');
const _minimizeKey = ValueKey('group-minimize');
const _expandKey = ValueKey('group-expand');

void main() {
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
      expect(tester.getSize(find.byKey(key)), const Size(30, 36));
      expect(_circle(tester, key).size, const Size.square(22));
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
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(platform: platform),
    home: Scaffold(body: Center(child: controls)),
  ),
);

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
