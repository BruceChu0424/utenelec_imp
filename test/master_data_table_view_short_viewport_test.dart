import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  testWidgets(
    'short table keeps rows and every toolbar action without pagination side effects',
    (tester) async {
      var actions = 0;
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 328,
              height: 200,
              child: MasterDataTableView<String>(
                columns: [
                  MasterColumnDef<String>(
                    key: 'goods',
                    label: '货品',
                    width: 180,
                    value: (row) => row,
                  ),
                ],
                items: const ['物料 A'],
                facets: const {},
                filters: const {},
                nullCounts: const {},
                onFilterChanged: (_, _) {},
                onLoadMore: () => loads++,
                toolbarLeadingActions: [
                  for (var i = 0; i < 8; i++)
                    SizedBox(
                      width: 220,
                      child: FilledButton(
                        onPressed: () => actions++,
                        child: Text('工具栏操作 $i'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final row = find.text('物料 A');
      expect(tester.getSize(row).height, greaterThan(0));
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(200));
      await tester.ensureVisible(find.text('工具栏操作 7'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('工具栏操作 7'));
      expect(actions, 1);
      expect(
        loads,
        0,
        reason: 'scrolling chrome must not request business pages',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a very short viewport can scroll to the usable row stage', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 328,
            height: 100,
            child: MasterDataTableView<String>(
              columns: [
                MasterColumnDef<String>(
                  key: 'goods',
                  label: '货品',
                  width: 180,
                  value: (row) => row,
                ),
              ],
              items: const ['物料 A'],
              facets: const {},
              filters: const {},
              nullCounts: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('物料 A'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('物料 A')).height, greaterThan(0));
    expect(tester.getRect(find.text('物料 A')).bottom, lessThanOrEqualTo(100));
    expect(tester.takeException(), isNull);
  });
}
