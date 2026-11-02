import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_action_overflow.dart';
import 'package:uten_imp/components/layout/uten_app_bar_action_scope.dart';

const _actionKey = Key('handoff-action');

Future<({ValueNotifier<int> epoch, ValueNotifier<int> source})> _pump(
  WidgetTester tester,
  void Function(int) action, {
  bool compact = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(compact ? 390 : 1200, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final epoch = ValueNotifier(0), source = ValueNotifier(0);
  addTearDown(epoch.dispose);
  addTearDown(source.dispose);
  final controls = ValueListenableBuilder<int>(
    valueListenable: source,
    builder: (_, revision, _) => UtenActionOverflow(
      forceCompact: compact,
      children: [
        UtenButton(
          key: _actionKey,
          closeBeforeAction: true,
          onPressed: () => action(revision),
          child: const Text('切换视图'),
        ),
      ],
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: epoch,
          child: controls,
          builder: (_, value, child) =>
              UtenActionOwnerScope(identity: value, child: child!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (epoch: epoch, source: source);
}

Future<VoidCallback> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
  expect(find.byKey(_actionKey).hitTestable(), findsOneWidget);
  return tester
      .widget<RawMaterialButton>(
        find.descendant(
          of: find.byKey(_actionKey),
          matching: find.byType(RawMaterialButton),
        ),
      )
      .onPressed!;
}

void main() {
  testWidgets('handoff closes the menu and claims an activation only once', (
    tester,
  ) async {
    final calls = <int>[];
    await _pump(tester, calls.add);
    final queuedActivation = await _open(tester);
    queuedActivation();
    queuedActivation();
    expect(calls, isEmpty, reason: 'The overlay still owns this frame');
    await tester.pumpAndSettle();
    expect(calls, [0]);
    expect(tester.takeException(), isNull);
  });

  for (final boundary in ['permission revocation', 'account A-B-A']) {
    testWidgets('$boundary retires a queued menu activation', (tester) async {
      final calls = <int>[];
      final fixture = await _pump(tester, calls.add);
      final queuedActivation = await _open(tester);
      queuedActivation();
      fixture.epoch.value++;
      if (boundary == 'account A-B-A') fixture.epoch.value++;
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('source revision changes retire the claimed old callback', (
    tester,
  ) async {
    final calls = <int>[];
    final fixture = await _pump(tester, calls.add);
    final queuedActivation = await _open(tester);
    queuedActivation();
    fixture.source.value++;
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    final current = await _open(tester);
    current();
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('controls outside a transient menu keep synchronous activation', (
    tester,
  ) async {
    final calls = <int>[];
    await _pump(tester, calls.add, compact: false);
    await tester.tap(find.byKey(_actionKey));
    expect(calls, [0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the source cancels a queued activation', (
    tester,
  ) async {
    final calls = <int>[];
    await _pump(tester, calls.add);
    final queuedActivation = await _open(tester);
    queuedActivation();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
