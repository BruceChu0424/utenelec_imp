import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_action.dart';

void main() {
  testWidgets('rich cell preserves material colours and keyboard activation', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenTableCellAction.rich(
            label: '缺 1 种 · 可领 6 种',
            textSpan: const TextSpan(
              children: [
                TextSpan(
                  text: '缺 1 种',
                  style: TextStyle(color: Colors.red),
                ),
                TextSpan(text: ' · '),
                TextSpan(
                  text: '可领 6 种',
                  style: TextStyle(color: Colors.blue),
                ),
              ],
            ),
            onPressed: () => opens++,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextButton));
    expect(opens, 1);
    final text = tester.widget<Text>(find.byType(Text));
    final spans = (text.textSpan! as TextSpan).children!;
    expect(spans.first.style!.color, Colors.red);
    expect(spans.last.style!.color, Colors.blue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opens, 2);
    expect(tester.takeException(), isNull);
  });
}
