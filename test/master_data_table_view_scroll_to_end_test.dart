import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.primary = false, this.virtualized = false});
  final bool primary;
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
  bool virtualized = false,
}) => MaterialApp(
  home: Scaffold(
    body: _Harness(key: key, primary: primary, virtualized: virtualized),
  ),
);

void main() {
  testWidgets(
    'primary owner replacement rebinds the position without remounting editors',
    (tester) async {
      final first = ScrollController();
      final second = ScrollController();
      final owner = ValueNotifier<ScrollController>(first);
      final input = TextEditingController(text: 'retained owner draft');
      final tableKey = GlobalKey();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(owner.dispose);
      addTearDown(input.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<ScrollController>(
              valueListenable: owner,
              builder: (_, controller, _) => PrimaryScrollController(
                controller: controller,
                child: MasterDataTableView<int>(
                  key: tableKey,
                  primary: true,
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      label: 'Name',
                      width: 250,
                      value: (row) => 'ROW-$row',
                      cellBuilder: (_, row) => SizedBox(
                        height: 240,
                        child: row == 0
                            ? SelectionContainer.disabled(
                                child: TextField(controller: input),
                              )
                            : Text('ROW-$row'),
                      ),
                    ),
                  ],
                  items: const [0, 1, 2],
                  idOf: (row) => '$row',
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester.state<EditableTextState>(find.byType(EditableText));
      final scrollable = Scrollable.of(editor.context, axis: Axis.vertical);
      final tableState = tableKey.currentState;
      expect(first.hasClients, isTrue);
      for (final next in [second, first]) {
        final previous = owner.value;
        owner.value = next;
        await tester.pumpAndSettle();
        expect(previous.hasClients, isFalse);
        expect(next.hasClients, isTrue);
        expect(scrollable.position, same(next.position));
        expect(tableKey.currentState, same(tableState));
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editor),
        );
        expect(input.text, 'retained owner draft');
        next.jumpTo(120);
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, 120);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'primary fullscreen preserves the live editor and scrollable in both directions',
    (tester) async {
      final input = TextEditingController(text: 'uncommitted draft');
      addTearDown(input.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NestedScrollView(
              headerSliverBuilder: (_, _) => [
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ],
              body: MasterDataTableView<int>(
                primary: true,
                columns: [
                  MasterColumnDef(
                    key: 'name',
                    label: 'Name',
                    width: 250,
                    value: (_) => input.text,
                    cellBuilder: (_, _) => SelectionContainer.disabled(
                      child: TextField(controller: input),
                    ),
                  ),
                ],
                items: const [0],
                idOf: (row) => '$row',
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(EditableText);
      final editor = tester.state<EditableTextState>(field);
      final scrollable = Scrollable.of(
        tester.element(field),
        axis: Axis.vertical,
      );
      for (var turn = 0; turn < 2; turn++) {
        await tester.tap(field);
        input.selection = const TextSelection(baseOffset: 2, extentOffset: 8);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('master-table-fullscreen-toggle')),
        );
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(field), same(editor));
        expect(
          Scrollable.of(tester.element(field), axis: Axis.vertical),
          same(scrollable),
        );
        expect(input.text, 'uncommitted draft');
        expect(
          input.selection,
          const TextSelection(baseOffset: 2, extentOffset: 8),
        );
        await tester.tap(
          find.byKey(const ValueKey('master-table-fullscreen-toggle')),
        );
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(field), same(editor));
        expect(
          tester
              .state<NestedScrollViewState>(find.byType(NestedScrollView))
              .innerController
              .positions,
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final mode in ['normal', 'virtualized', 'primary']) {
    testWidgets('$mode: empty to populated request reveals final row once', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        _app(
          key,
          primary: mode == 'primary',
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
