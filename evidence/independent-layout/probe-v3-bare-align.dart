import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';

Widget _host({
  required GlobalKey<TooltipState> tooltip,
  required bool inLeading,
  required bool withTooltip,
  ValueNotifier<double>? width,
}) {
  Widget pane(bool leading) => Align(
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading == inLeading && withTooltip)
            Tooltip(
              key: tooltip,
              message: 'hovered retained source',
              child: const Text('source control'),
            )
          else
            const Text('plain control'),
          if (!leading)
            const TextField(key: ValueKey('retained-input')),
        ],
      ),
  );
  return MaterialApp(
    theme: ThemeData(platform: TargetPlatform.windows),
    home: Scaffold(
      body: ValueListenableBuilder<double>(
        valueListenable: width ?? ValueNotifier(1280),
        builder: (context, value, child) => Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: value, child: child),
        ),
        child: UtenSplitView(
        selectedLeadingLabel: 'all sources',
        leading: pane(true),
        trailing: pane(false),
        ),
      ),
    ),
  );
}

void main() {
  for (final inLeading in [true, false]) {
    for (final withTooltip in [false, true]) {
      testWidgets('retained ${inLeading ? 'leading' : 'trailing'} '
          '${withTooltip ? 'visible tooltip' : 'plain legal control'} '
          'survives wide to narrow', (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final key = GlobalKey<TooltipState>();
        await tester.pumpWidget(_host(
          tooltip: key,
          inLeading: inLeading,
          withTooltip: withTooltip,
        ));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('retained-input')),
            'unsaved 7.125');
        if (withTooltip) {
          expect(key.currentState!.ensureTooltipVisible(), isTrue);
          await tester.pumpAndSettle();
          expect(find.text('hovered retained source'), findsOneWidget);
        }
        tester.view.physicalSize = const Size(714, 764);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('unsaved 7.125'), findsOneWidget);
      });
    }
  }

  testWidgets('physical mouse hover tooltip survives first narrowing',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final key = GlobalKey<TooltipState>();
    await tester.pumpWidget(_host(
      tooltip: key,
      inLeading: true,
      withTooltip: true,
    ));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('source control')));
    await tester.pumpAndSettle();
    expect(find.text('hovered retained source'), findsOneWidget);
    tester.view.physicalSize = const Size(714, 764);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
  });

  for (final leading in [true, false]) {
    for (final show in [false, true]) {
      testWidgets('local constraints change under stable overlay '
          '${leading ? 'leading' : 'trailing'} ${show ? 'tooltip' : 'plain'}',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1600, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final width = ValueNotifier<double>(1280);
        addTearDown(width.dispose);
        final key = GlobalKey<TooltipState>();
        await tester.pumpWidget(_host(
          tooltip: key,
          inLeading: leading,
          withTooltip: show,
          width: width,
        ));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('retained-input')),
            'unsaved exact 7.125');
        if (show) {
          expect(key.currentState!.ensureTooltipVisible(), isTrue);
          await tester.pumpAndSettle();
          expect(find.text('hovered retained source'), findsOneWidget);
        }
        width.value = 714;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('unsaved exact 7.125'), findsOneWidget);
      });
    }
  }
}
