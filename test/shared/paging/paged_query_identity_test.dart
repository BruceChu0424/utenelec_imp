import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/paging/paged_query_identity.dart';

void main() {
  test('scope collections compare values across fresh maps and key order', () {
    final before = (
      'report',
      PagedReadQueryKey({
        'search': {'name': '原料', 'amount': '>0'},
        'kinds': ['OPEN', 'READY'],
      }),
    );
    final rebuilt = (
      'report',
      PagedReadQueryKey({
        'kinds': ['OPEN', 'READY'],
        'search': {'amount': '>0', 'name': '原料'},
      }),
    );
    expect(rebuilt, before);
    expect(rebuilt.hashCode, before.hashCode);
    expect((
      'report',
      PagedReadQueryKey({
        'search': {'name': '新条件'},
      }),
    ), isNot(before));
  });

  test('a later filter mutation cannot rewrite the accepted scope', () {
    final filters = <String, Object?>{
      'search': <String, String>{'name': '旧条件'},
      'kinds': <String>['OPEN'],
    };
    final accepted = PagedReadQueryKey(filters);
    (filters['search']! as Map<String, String>)['name'] = '新条件';
    (filters['kinds']! as List<String>).add('READY');
    expect(
      accepted,
      PagedReadQueryKey({
        'search': {'name': '旧条件'},
        'kinds': ['OPEN'],
      }),
    );
    expect(accepted, isNot(PagedReadQueryKey(filters)));
  });

  testWidgets(
    'a rebuilt filter scope preserves scroll; a new query resets it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(700, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final filters = ValueNotifier(<String, String>{'name': '原条件'});
      addTearDown(filters.dispose);
      final rows = List.generate(50, (index) => 'row-$index');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<Map<String, String>>(
              valueListenable: filters,
              builder: (_, query, _) => MasterDataTableView<String>(
                paginationScope: ('ledger', PagedReadQueryKey(query)),
                columns: [
                  MasterColumnDef(
                    key: 'name',
                    label: '记录',
                    width: 200,
                    value: (row) => row,
                  ),
                ],
                items: rows,
                rowKeyOf: (row) => row,
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
      final position = Scrollable.of(
        tester.element(find.text('row-0')),
        axis: Axis.vertical,
      ).position;
      position.jumpTo(220);
      await tester.pumpAndSettle();
      expect(position.pixels, 220);
      filters.value = Map.of(filters.value);
      await tester.pumpAndSettle();
      expect(position.pixels, 220);
      filters.value = {'name': '新条件'};
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
