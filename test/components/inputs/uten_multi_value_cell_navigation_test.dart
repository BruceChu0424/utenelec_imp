import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_multi_value_cell.dart';

void main() {
  testWidgets('detail closes the root dialog before navigating a nested page', (
    tester,
  ) async {
    final nested = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          key: nested,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Center(
                child: UtenMultiValueCell(
                  values: const ['ZX0000048'],
                  onDetail: (_) => nested.currentState!.push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('工单详情')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ZX0000048'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('multi-value-detail-ZX0000048')),
    );
    await tester.pumpAndSettle();
    expect(find.text('工单详情'), findsOneWidget);
    expect(find.text('共 1 项：'), findsNothing);
    nested.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('ZX0000048'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
