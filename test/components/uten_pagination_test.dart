import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_pagination.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'continuous list has no page input or navigation on $platform',
      (tester) async {
        final controller = TextEditingController(text: 'host owned');
        addTearDown(controller.dispose);
        final reads = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
              child: Scaffold(
                body: Center(
                  child: UtenPagination(
                    currentPage: 7,
                    totalPages: null,
                    maxPage: 8,
                    onPageChanged: reads.add,
                    controller: controller,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(TextFormField), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(
          find.byKey(const ValueKey('master-table-page-next')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('master-table-page-previous')),
          findsNothing,
        );
        expect(tester.getSize(find.byType(UtenPagination)), Size.zero);
        expect(controller.text, 'host owned');
        expect(reads, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
