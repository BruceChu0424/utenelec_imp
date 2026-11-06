import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';

class _Row {
  const _Row(this.id, this.version);
  final int id;
  final int version;
}

PagedResult<_Row> _page(int page, {int version = 0, int shift = 0}) =>
    PagedResult(
      items: [
        for (var id = (page - 1) * 14; id < page * 14; id++)
          _Row(id + shift, version),
      ],
      page: page,
      size: 14,
      total: 42,
      totalPages: 3,
    );

class _Harness extends StatefulWidget {
  const _Harness({super.key});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final reader = ScopedPagedRead<_Row>(idOf: (row) => row.id);
  final rows = MasterDataTableRowsController<_Row>();
  PagedResult<_Row>? result;
  bool loading = false;
  String? error;
  int request = 0;
  Future<PagedResult<_Row>> Function(int) source = (page) async => _page(page);

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    final generation = ++request;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final next = await reader.read(
        1,
        scope: 'fixed-query',
        fetchPage: source,
        isCurrent: () => mounted,
      );
      if (!mounted || generation != request) return;
      setState(() => result = next);
    } catch (failure) {
      if (!mounted || generation != request) return;
      setState(() {
        error = failure is ApiException ? failure.message : '$failure';
        if (pagedReadAccessDenied(failure)) result = null;
      });
    } finally {
      if (mounted && generation == request) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    reader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: MasterDataTableView<_Row>(
        columns: [
          MasterColumnDef<_Row>(
            key: 'label',
            label: '名称',
            width: 400,
            value: (row) => '${row.id} v${row.version}',
            cellBuilder: (_, row) => SizedBox(
              key: ValueKey('row-${row.id}'),
              height: 34 + row.id % 3 * 12 + row.version * 5,
              child: Text('${row.id} v${row.version}'),
            ),
          ),
        ],
        rowKeyOf: (row) => '${row.id}',
        rowsController: rows,
        items: result?.items ?? const [],
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        paginationScope: 'fixed-query',
        paginationRevision: result,
        isLoading: loading && result == null,
        isRefreshing: loading && result != null,
        error: error,
      ),
    ),
  );
}

Future<_HarnessState> _loaded(WidgetTester tester) async {
  final key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(_Harness(key: key));
  await tester.pumpAndSettle();
  expect(key.currentState!.rows.items, hasLength(42));
  return key.currentState!;
}

Future<void> _finish(WidgetTester tester, Future<void> pending) async {
  await tester.pumpAndSettle();
  await pending;
  await tester.pumpAndSettle();
}

void main() {
  test(
    'business projections retain owner proof, including empty projections',
    () {
      final session = PagedReadWindowSession<int>(isCurrent: () => true);
      const original = PagedResult<int>(
        items: [1, 2, 3, 4],
        page: 1,
        size: 4,
        total: 4,
        totalPages: 1,
      );
      session.bindResult(original);
      List<String> project(List<int> rows) =>
          rows.where((n) => n.isEven).map((n) => 'view-$n').toList();
      final view = project(original.items);
      projectReadWindowBinding(
        original.items,
        view,
        project: project,
        projectionKey: ['even', 1],
      );
      final binding = readWindowBindingOf(view)!;
      expect(binding.isCurrent, isTrue);
      final emptyView = projectReadWindowBinding(
        original.items,
        <String>[],
        project: (_) => <String>[],
        projectionKey: ['even', 2],
      );
      expect(readWindowBindingOf(emptyView)!.sameSession(binding), isFalse);
      session.invalidate();
      expect(binding.isCurrent, isFalse);
      expect(readWindowBindingOf(emptyView)!.isCurrent, isFalse);
    },
  );

  for (final shift in [0, 1]) {
    testWidgets(
      'refresh replaces the complete result atomically with shift $shift',
      (tester) async {
        final host = await _loaded(tester);
        final gate = Completer<PagedResult<_Row>>();
        final calls = <int>[];
        host.source = (page) {
          calls.add(page);
          return page == 2
              ? gate.future
              : Future.value(_page(page, version: 1, shift: shift));
        };
        final before = host.rows.items.toList();
        final state = tester.state(find.byType(MasterDataTableView<_Row>));
        final pending = host.load();
        await tester.pump();
        expect(host.rows.items, orderedEquals(before));
        expect(calls, [1, 2]);
        gate.complete(_page(2, version: 1, shift: shift));
        await _finish(tester, pending);
        expect(calls, [1, 2, 3]);
        expect(
          host.rows.items.map((r) => r.id),
          List.generate(42, (i) => i + shift),
        );
        expect(host.rows.items.every((r) => r.version == 1), isTrue);
        expect(
          tester.state(find.byType(MasterDataTableView<_Row>)),
          same(state),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('ordinary failure retains authorized rows; denial retires them', (
    tester,
  ) async {
    final host = await _loaded(tester);
    final old = host.rows.items.toList();
    host.source = (_) => Future.error(ApiException('NETWORK', 'offline'));
    await _finish(tester, host.load());
    expect(host.rows.items, orderedEquals(old));
    host.source = (_) =>
        Future.error(ApiException('FORBIDDEN', 'denied', httpStatus: 403));
    await _finish(tester, host.load());
    expect(host.rows.items, isEmpty);
    expect(find.text('denied'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('master-table-initial-read-details')),
    );
    await tester.pumpAndSettle();
    expect(find.text('denied'), findsOneWidget);
    await tester.tap(find.byType(UtenCloseButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful empty refresh clears the complete result', (
    tester,
  ) async {
    final host = await _loaded(tester);
    host.source = (_) async => const PagedResult<_Row>(
      items: [],
      page: 1,
      size: 14,
      total: 0,
      totalPages: 0,
    );
    await _finish(tester, host.load());
    expect(host.rows.items, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'retired owner hides selected DTOs, local projections and groups without deleting source drafts',
    (tester) async {
      final session = PagedReadWindowSession<String>(isCurrent: () => true);
      const result = PagedResult<String>(
        items: ['private remote'],
        page: 1,
        size: 1,
        total: 1,
        totalPages: 1,
      );
      session.bindResult(result);
      final localDrafts = ['private local draft'];
      final rows = MasterDataTableRowsController<String>();
      final tick = ValueNotifier(0);
      addTearDown(tick.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: tick,
              builder: (_, _, _) => MasterDataTableView<String>(
                items: result.items,
                unpagedItems: localDrafts,
                leadingGroups: const [
                  MasterDataGroup(
                    id: 'private',
                    title: 'private group',
                    items: ['private grouped row'],
                    initiallyExpanded: true,
                  ),
                ],
                selectedIds: const {'private remote'},
                selectable: true,
                batchActionsBuilder: (_, _) => [
                  TextButton(onPressed: () {}, child: const Text('处理原选中项')),
                ],
                idOf: (row) => row,
                rowKeyOf: (row) => row,
                rowsController: rows,
                columns: [
                  MasterColumnDef(
                    key: 'value',
                    label: '名称',
                    width: 400,
                    value: (row) => row,
                  ),
                ],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                paginationScope: 'one authorized query',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(rows.items, contains('private remote'));
      expect(find.text('处理原选中项'), findsOneWidget);
      expect(find.textContaining('private group'), findsWidgets);
      session.invalidate();
      tick.value++;
      await tester.pumpAndSettle();
      expect(rows.items, isEmpty);
      expect(find.text('处理原选中项'), findsNothing);
      expect(find.textContaining('private remote'), findsNothing);
      expect(find.textContaining('private local draft'), findsNothing);
      expect(find.textContaining('private group'), findsNothing);
      expect(localDrafts, ['private local draft']);
      expect(tester.takeException(), isNull);
    },
  );
}
