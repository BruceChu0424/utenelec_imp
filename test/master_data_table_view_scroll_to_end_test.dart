import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.primary = false,
    this.cards = false,
    this.virtualized = false,
  });
  final bool primary;
  final bool cards;
  final bool virtualized;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int count = 0;
  int page = 1;
  int request = 0;

  void update({int? count, int? page, int? request}) => setState(() {
    this.count = count ?? this.count;
    this.page = page ?? this.page;
    this.request = request ?? this.request;
  });

  @override
  Widget build(BuildContext context) {
    final table = MasterDataTableView<int>(
      columns: [
        MasterColumnDef<int>(
          key: 'name',
          label: 'Name',
          width: 250,
          value: (row) => 'ROW-$row',
          cellBuilder: (context, row) => SizedBox(
            height: 30 + (row % 4) * 15,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('ROW-$row'),
            ),
          ),
        ),
      ],
      items: List.generate(count, (i) => i),
      primary: widget.primary,
      compactCards: widget.cards,
      cardBelowWidth: 1000,
      virtualized: widget.virtualized,
      enableTextSelection: false,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      currentPage: page,
      totalPages: 4,
      onPageChange: (next) => update(page: next),
      scrollToEndRequest: request,
    );
    return widget.primary
        ? NestedScrollView(
            headerSliverBuilder: (_, _) => [
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
            body: table,
          )
        : table;
  }
}

Widget _app(
  GlobalKey<_HarnessState> key, {
  bool primary = false,
  bool cards = false,
  bool virtualized = false,
}) => MaterialApp(
  home: Scaffold(
    body: _Harness(
      key: key,
      primary: primary,
      cards: cards,
      virtualized: virtualized,
    ),
  ),
);

void main() {
  for (final mode in ['normal', 'virtualized', 'cards', 'primary']) {
    testWidgets('$mode: empty to populated request reveals final row once', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        _app(
          key,
          primary: mode == 'primary',
          cards: mode == 'cards',
          virtualized: mode == 'virtualized',
        ),
      );
      await tester.pumpAndSettle();
      key.currentState!.update(count: 80, page: 2, request: 1);
      await tester.pumpAndSettle();
      expect(find.text('ROW-79').hitTestable(), findsOneWidget);
      expect(find.text('ROW-0').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);

      final scroll = Scrollable.of(
        tester.element(find.text('ROW-79')),
      ).position;
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      key.currentState!.update();
      await tester.pumpAndSettle();
      expect(
        find.text('ROW-0').hitTestable(),
        findsOneWidget,
        reason: 'An unchanged token must not drag the user back to the end.',
      );

      key.currentState!.update(request: 2);
      await tester.pumpAndSettle();
      expect(find.text('ROW-79').hitTestable(), findsOneWidget);
      key.currentState!.update(page: 1);
      await tester.pumpAndSettle();
      expect(
        find.text('ROW-0').hitTestable(),
        findsOneWidget,
        reason: 'Ordinary pagination must retain reset-to-top.',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('primary fullscreen request waits for refreshed route layout', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_app(key, primary: true));
    key.currentState!.update(count: 1);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('master-table-fullscreen-toggle')),
    );
    await tester.pumpAndSettle();
    key.currentState!.update(count: 80, page: 2, request: 1);
    await tester.pumpAndSettle();
    expect(find.text('ROW-79').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey('master-table-fullscreen-toggle')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing with a pending layout correction is safe', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_app(key, virtualized: true));
    key.currentState!.update(count: 80, request: 1);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
