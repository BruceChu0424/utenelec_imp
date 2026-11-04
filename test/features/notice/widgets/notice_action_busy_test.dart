import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/features/notice/widgets/notice_action_busy.dart';

void main() {
  testWidgets(
    'notice action mask follows route visibility without replaying writes',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final gate = Completer<void>();
      var writes = 0;
      Future<void>? pending;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  pending = runNoticeActionWithBusy(
                    context,
                    title: '正在确认收到',
                    action: () async {
                      writes++;
                      await gate.future;
                    },
                  );
                },
                child: const Text('收到'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('收到'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(writes, 1);

      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('另一个页面')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(writes, 1);

      gate.complete();
      await pending;
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'immediate failure removes the notice mask before error recovery',
    (tester) async {
      late BuildContext owner;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              owner = context;
              return const Scaffold(body: Text('通知'));
            },
          ),
        ),
      );
      await expectLater(
        runNoticeActionWithBusy<void>(
          owner,
          title: '正在确认收到',
          action: () async {
            throw StateError('offline');
          },
        ),
        throwsStateError,
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
