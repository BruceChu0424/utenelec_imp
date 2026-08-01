import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/click_guard.dart';

void main() {
  test(
    'ClickGuard blocks re-entry and unlocks after synchronous failures',
    () async {
      final guard = ClickGuard();
      var calls = 0;

      final first = guard.run(() {
        calls++;
        throw StateError('boom');
      });
      expect(first, isNotNull);
      expect(guard.isBusy, isTrue);
      expect(guard.run(() async => calls++), isNull);

      await expectLater(first, throwsStateError);
      expect(guard.isBusy, isFalse);

      await guard.run(() async => calls++);
      expect(calls, 2);
    },
  );

  testWidgets('UtenActionButton exposes semantics and renders busy state', (
    tester,
  ) async {
    final completer = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenActionButton(
            label: const Text('提交'),
            loadingLabel: const Text('提交中'),
            onAction: () {
              calls++;
              return completer.future;
            },
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(UtenActionButton)),
      matchesSemantics(
        label: '提交',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('提交中'), findsOneWidget);

    await tester.tap(find.byType(UtenActionButton));
    await tester.pump();
    expect(calls, 1);

    completer.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('提交'), findsOneWidget);
  });

  testWidgets('UtenActionButton keeps a 44dp square touch target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenActionButton(
            size: UtenActionButtonSize.small,
            label: const Text('I'),
            onAction: () async {},
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(UtenActionButton));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });
}
