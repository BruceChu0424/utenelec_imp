import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

/// An offset-exact server: page `p` of size `s` returns rows (p-1)*s … p*s-1.
Future<PagedResult<String>> _load(int page, int size, {int total = 450}) async {
  final start = (page - 1) * size;
  final end = (start + size).clamp(0, total);
  return PagedResult<String>(
    items: [for (var i = start; i < end; i++) 'row-$i'],
    page: page,
    size: size,
    total: total,
    totalPages: (total + size - 1) ~/ size,
    readScopeVersion: 'scope-a',
  );
}

void main() {
  // A complete read that failed after publishing progressive rows retires its
  // session; the host may still pass the withdrawn prefix as `items`. That is
  // not an empty result: the table keeps the read-failure notice with its
  // retry instead of falling through to the "no data" empty state.
  testWidgets('a withdrawn progressive prefix never renders as 0 rows', (
    tester,
  ) async {
    final published = <PagedResult<String>>[];
    final reader = ScopedPagedRead<String>(idOf: (row) => row);
    // The shared reader paces publication with real timers and yields.
    await tester.runAsync(
      () => expectLater(
        reader.read(
          1,
          scope: 'retired-owner',
          fetchPage: (page) => _load(page, 100),
          fetchPageSized: (page, size) => size == 200
              ? throw StateError('stream broke')
              : _load(page, size),
          isCurrent: () => true,
          onProgressiveBatch: published.add,
        ),
        throwsStateError,
      ),
    );
    final withdrawn = published.last.items;
    expect(readWindowBindingOf(withdrawn)!.isCurrent, isFalse);

    var items = withdrawn;
    var retries = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, change) {
              update = change;
              return MasterDataTableView<String>(
                key: const Key('retired-table'),
                items: items,
                columns: [
                  MasterColumnDef(
                    key: 'id',
                    label: '编号',
                    width: 300,
                    value: (row) => row,
                  ),
                ],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                onRetry: () => retries++,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无数据'), findsNothing);
    expect(find.text('row-0'), findsNothing);
    // error == null here: only the withdrawn-read branch can show this notice.
    expect(find.text('数据加载失败'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('master-table-initial-read-details')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? '').contains('读取未完成'),
      ),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试').first);
    expect(retries, 1);

    // A host that really has no rows still shows the ordinary empty state.
    update(() => items = const <String>[]);
    await tester.pumpAndSettle();
    expect(find.text('数据加载失败'), findsNothing);
    expect(find.text('暂无数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
