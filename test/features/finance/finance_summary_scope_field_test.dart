import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/finance/shared/finance_complete_summary_read.dart';
import 'package:uten_imp/features/finance/widgets/finance_summary_scope_field.dart';

void main() {
  for (final scale in [1.0, 1.5]) {
    for (final availableWidth in <double?>[null, 320, 160]) {
      testWidgets(
        'summary range field has finite width: $availableWidth x$scale',
        (tester) async {
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) {
                      final field = FinanceSummaryScopeField(
                        value: FinanceSummaryScope.active,
                        onChanged: (_) {},
                      );
                      return availableWidth == null
                          ? Row(
                              children: [
                                Wrap(children: [field]),
                              ],
                            )
                          : SizedBox(width: availableWidth, child: field);
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final size = tester.getSize(find.byType(UtenDropdownField));
          expect(size.width, availableWidth ?? 200);
          expect(size.width.isFinite, isTrue);
          expect(size.height, greaterThan(0));
          expect(find.text('待办理'), findsOneWidget);
        },
      );
    }
  }
}
