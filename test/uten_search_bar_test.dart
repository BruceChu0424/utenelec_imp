import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';

void main() {
  testWidgets('clear emits once and cancels a pending debounced search', (
    tester,
  ) async {
    final changes = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenSearchBar(
            debounce: const Duration(milliseconds: 100),
            onChanged: changes.add,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'query');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();

    expect(changes, const ['']);
    expect(find.text('query'), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    expect(changes, const ['']);
  });
}
