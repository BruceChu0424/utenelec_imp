import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _HeldRun {
  final completion = Completer<void>();
  Future<void>? pending;
  var calls = 0;
  var finished = false;

  void start(BuildContext owner) {
    pending = UtenBusyOverlay.run<void>(
      owner,
      title: '原操作等待中',
      action: () {
        calls++;
        return completion.future;
      },
    ).then((_) => finished = true);
    unawaited(pending);
  }

  Future<void> finish() async {
    if (!completion.isCompleted) completion.complete();
    await pending;
  }
}

class _CallingOwner {
  final navigator = GlobalKey<NavigatorState>();
  late BuildContext context;
  late StateSetter update;
  var ticker = true;
  var show = true;

  Future<void> mount(WidgetTester tester, _HeldRun task) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return Scaffold(
              body: TickerMode(
                enabled: ticker,
                child: show
                    ? Builder(
                        builder: (owner) {
                          context = owner;
                          return TextButton(
                            onPressed: () => task.start(owner),
                            child: const Text('开始原操作'),
                          );
                        },
                      )
                    : const Text('新的拥有者'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('开始原操作'));
    await _frames(tester);
  }
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);
  tearDown(UtenBusyOverlay.debugResetYield);

  testWidgets(
    'run follows the actual calling route through cover and pop without completing or dispatching again',
    (tester) async {
      final task = _HeldRun(), owner = _CallingOwner();
      await owner.mount(tester, task);
      expect(task.calls, 1);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      final cover = DialogRoute<void>(
        context: owner.context,
        builder: (_) => const AlertDialog(title: Text('新的交互弹窗')),
      );
      unawaited(owner.navigator.currentState!.push(cover));
      try {
        await _frames(tester);
        expect(cover.isCurrent, isTrue);
        expect(task.completion.isCompleted, isFalse);
        expect(task.finished, isFalse);
        expect(task.calls, 1);
        expect(find.byType(UtenBusyOverlayCard), findsNothing);
        owner.navigator.currentState!.removeRoute(cover);
        await _frames(tester);
        expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
        expect(task.finished, isFalse);
        expect(task.calls, 1);
      } finally {
        if (cover.isActive) owner.navigator.currentState!.removeRoute(cover);
        await task.finish();
        await _frames(tester);
      }
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(task.finished, isTrue);
      expect(task.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'run follows the calling owner ticker off and on while the original future stays pending',
    (tester) async {
      final task = _HeldRun(), owner = _CallingOwner();
      await owner.mount(tester, task);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      try {
        owner.update(() => owner.ticker = false);
        await _frames(tester);
        expect(owner.context.mounted, isTrue);
        expect(task.completion.isCompleted, isFalse);
        expect(task.finished, isFalse);
        expect(find.byType(UtenBusyOverlayCard), findsNothing);
        owner.update(() => owner.ticker = true);
        await _frames(tester);
        expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
        expect(task.calls, 1);
        expect(task.finished, isFalse);
      } finally {
        await task.finish();
        await _frames(tester);
      }
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(task.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing the calling owner retires only its run presentation and preserves the pending original operation',
    (tester) async {
      final task = _HeldRun(), owner = _CallingOwner();
      await owner.mount(tester, task);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      try {
        owner.update(() => owner.show = false);
        await _frames(tester);
        expect(owner.context.mounted, isFalse);
        expect(find.text('新的拥有者'), findsOneWidget);
        expect(task.completion.isCompleted, isFalse);
        expect(task.finished, isFalse);
        expect(task.calls, 1);
        expect(find.byType(UtenBusyOverlayCard), findsNothing);
      } finally {
        await task.finish();
        await _frames(tester);
      }
      expect(task.finished, isTrue);
      expect(task.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
