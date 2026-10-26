import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Pages extends StatefulWidget {
  const _Pages({super.key});
  @override
  State<_Pages> createState() => _PagesState();
}

class _PagesState extends State<_Pages> {
  final rows = MasterDataTableRowsController<int>();
  int page = 1;
  List<int> items = List.generate(50, (index) => index);
  @override
  Widget build(BuildContext context) => MasterDataTableView<int>(
    rowsController: rows,
    items: items,
    virtualized: true,
    selectable: true,
    idOf: (row) => '$row',
    rowKeyOf: (row) => '$row',
    maxRetainedPages: 2,
    maxRetainedRows: 100,
    currentPage: page,
    totalPages: 10,
    paginationScope: 'same',
    columns: [
      MasterColumnDef<int>(
        key: 'name',
        label: '货品',
        width: 160,
        value: (row) => '$row',
      ),
    ],
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    onPageChange: (target) => setState(() {
      page = target;
      items = List.generate(50, (index) => (target - 1) * 50 + index);
    }),
  );
}

void main() {
  testWidgets(
    'plain pages evict with exact shared geometry without mounting fifty hidden rows',
    (tester) async {
      final key = GlobalKey<_PagesState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(body: _Pages(key: key)),
        ),
      );
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await host.rows.loadNextPage();
      await tester.pumpAndSettle();
      expect(host.rows.items, hasLength(100));
      final position = tester
          .stateList<ScrollableState>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            ),
          )
          .singleWhere((state) => state.position.axis == Axis.vertical)
          .position;
      position.jumpTo(position.maxScrollExtent);
      var frames = 0;
      while (!host.rows.items.contains(149) && frames < 60) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
      }
      expect(host.rows.items, List.generate(100, (i) => i + 50));
      expect(
        frames,
        lessThan(12),
        reason:
            'known single-line geometry must not remount one hidden row per frame',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
