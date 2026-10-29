import 'dart:async';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';

const _expandKey = Key('native-expand');
const _minimizeKey = Key('native-minimize');
const _closeKey = Key('native-close');

void main() {
  testWidgets('native resize cycles retain one stable accessible control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final expanded = ValueNotifier(false);
    addTearDown(expanded.dispose);
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: expanded,
            builder: (context, value, _) => Align(
              alignment: Alignment.topRight,
              child: UtenWindowControls(
                native: true,
                showExpand: true,
                showMinimize: true,
                expanded: value,
                expandButtonKey: _expandKey,
                minimizeButtonKey: _minimizeKey,
                closeButtonKey: _closeKey,
                onClose: () {},
                onMinimize: () {},
                onExpand: () {
                  toggles++;
                  expanded.value = !expanded.value;
                },
              ),
            ),
          ),
        ),
      ),
    );
    final initialNode = tester.getSemantics(find.bySemanticsLabel('Maximize'));
    final initialNodeId = initialNode.id;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();

    for (var cycle = 0; cycle < 30; cycle++) {
      await mouse.moveTo(tester.getCenter(find.byKey(_expandKey)));
      // A normal Tooltip would be visible and contribute an overlay semantics
      // subtree by this point. Native controls must retain a single node.
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(Tooltip), findsNothing);
      expect(
        find.bySemanticsLabel(expanded.value ? 'Restore' : 'Maximize'),
        findsOneWidget,
      );
      var node = tester.getSemantics(
        find.bySemanticsLabel(expanded.value ? 'Restore' : 'Maximize'),
      );
      expect(node.id, initialNodeId);
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(
        node.getSemanticsData().flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      await tester.tap(find.byKey(_expandKey));
      await tester.binding.setSurfaceSize(
        expanded.value ? const Size(1400, 900) : const Size(900, 600),
      );
      await tester.pump();
      node = tester.getSemantics(
        find.bySemanticsLabel(expanded.value ? 'Restore' : 'Maximize'),
      );
      expect(node.id, initialNodeId);
      expect(
        find.bySemanticsLabel(expanded.value ? 'Restore' : 'Maximize'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Minimize'), findsOneWidget);
      expect(find.bySemanticsLabel('Close'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(toggles, 30);
    semantics.dispose();
  });

  testWidgets(
    'pending native action keeps enabled semantics and guards repeats',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final pending = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenWindowControlButton.expand(
              key: _expandKey,
              native: true,
              onPressed: () {
                calls++;
                return pending.future;
              },
            ),
          ),
        ),
      );
      final id = tester.getSemantics(find.bySemanticsLabel('Maximize')).id;
      await tester.tap(find.byKey(_expandKey));
      await tester.pump();
      await tester.tap(find.byKey(_expandKey));
      await tester.pump();
      expect(calls, 1);
      final node = tester.getSemantics(find.bySemanticsLabel('Maximize'));
      expect(node.id, id);
      expect(
        node.getSemanticsData().flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      pending.complete();
      await tester.pump();
      await tester.tap(find.byKey(_expandKey));
      await tester.pump();
      expect(calls, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 3);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('disabled native control stays labelled and non-actionable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenWindowControlButton.expand(
            key: _expandKey,
            native: true,
            onPressed: null,
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.bySemanticsLabel('Maximize'));
    final data = node.getSemanticsData();
    expect(data.label, 'Maximize');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    semantics.dispose();
  });

  testWidgets('business dismissers still disable until their guard completes', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenCloseButton(
            key: _closeKey,
            onPressed: () {
              calls++;
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_closeKey));
    await tester.pump();
    final button = find.descendant(
      of: find.byKey(_closeKey),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    await tester.tap(find.byKey(_closeKey));
    await tester.pump();
    expect(calls, 1);
    pending.complete();
    await tester.pump();
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
