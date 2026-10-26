import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_load_more_boundary.dart';

void main() {
  testWidgets('a changed scope never prefetches from old near-edge metrics', (
    tester,
  ) async {
    final controller = ScrollController();
    final scope = ValueNotifier(0);
    final responses = <Completer<void>>[];
    final requests = <int>[];
    addTearDown(controller.dispose);
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 260,
            width: 400,
            child: ValueListenableBuilder<int>(
              valueListenable: scope,
              builder: (_, value, _) => UtenLoadMoreBoundary(
                scope: value,
                enabled: true,
                onLoadMore: () {
                  requests.add(value);
                  final pending = Completer<void>();
                  responses.add(pending);
                  return pending.future;
                },
                child: ListView.builder(
                  controller: controller,
                  itemCount: value == 0 ? 30 : 100,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 48, child: Text('scope$value-$i')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    controller.jumpTo(controller.position.maxScrollExtent - 100);
    await tester.pump();
    expect(requests, [0]);
    scope.value = 1;
    await tester.pump();
    await tester.pump();
    responses.first.complete();
    await tester.pump();
    expect(requests, [
      0,
    ], reason: 'Changing scope or its dimensions never initiates a read');
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ListView)),
        scrollDelta: const Offset(0, 32),
      ),
    );
    await tester.pump();
    expect(
      requests,
      [0],
      reason: 'The new real viewport is far from its new trailing boundary',
    );
    controller.jumpTo(controller.position.maxScrollExtent - 100);
    await tester.pump();
    expect(requests, [0, 1]);
    responses.last.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final count in [1, 30]) {
    testWidgets('bottom wheel loads once for $count retained rows', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final pending = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 260,
              width: 400,
              child: UtenLoadMoreBoundary(
                enabled: true,
                onLoadMore: () {
                  calls++;
                  return pending.future;
                },
                child: ListView.builder(
                  controller: controller,
                  itemCount: count,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 48, child: Text('row-$i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(calls, count == 1 ? 0 : 1);
      final center = tester.getCenter(find.byType(ListView));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
      );
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(calls, count == 1 ? 0 : 1);
      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pump();
      }
      expect(calls, 1);
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disabled edge does not repeatedly retry a failure', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenLoadMoreBoundary(
            enabled: false,
            onLoadMore: () async {
              calls++;
            },
            child: ListView(children: const [Text('kept row')]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ListView)),
        scrollDelta: const Offset(0, 100),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('kept row'), findsOneWidget);
  });
}
