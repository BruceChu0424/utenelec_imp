import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_picker_icon_button.dart';

Widget _host({Future<void> Function()? action, bool loading = false}) =>
    MaterialApp(
      home: Scaffold(
        body: UtenPickerIconButton(
          tooltip: '选择货品',
          onPressed: action,
          isLoading: loading,
        ),
      ),
    );

void main() {
  testWidgets('an open selection route mutes the covered button animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => UtenPickerIconButton(
              tooltip: '选择货品',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('完成选择'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('选择货品'));
    await tester.pumpAndSettle();
    expect(find.text('完成选择'), findsOneWidget);
    await tester.tap(find.text('完成选择'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker icon keeps its label and blocks a second open', (
    tester,
  ) async {
    final pending = Completer<void>();
    var opens = 0;
    await tester.pumpWidget(
      _host(
        action: () {
          opens++;
          return pending.future;
        },
      ),
    );
    expect(find.text('选择货品'), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('选择货品'));
    await tester.pump();
    await tester.tap(find.byTooltip('选择货品'));
    expect(opens, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'keyboard can open the picker and an absent callback is disabled',
    (tester) async {
      var opens = 0;
      await tester.pumpWidget(_host(action: () async => opens++));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opens, 1);
      await tester.pumpWidget(_host());
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
    },
  );

  testWidgets('closing the owner during selection ignores its late receipt', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(_host(action: () => pending.future));
    await tester.tap(find.byTooltip('选择货品'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
