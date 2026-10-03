import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_load_more_boundary.dart';

void main() {
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
      expect(calls, 0);
      final center = tester.getCenter(find.byType(ListView));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
      );
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(calls, 0);
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
