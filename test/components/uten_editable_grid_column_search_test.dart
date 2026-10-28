import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Row extends EditableGridRow {
  _Row(this.id, String name, this.color, this.series, this.kind)
    : name = TextEditingController(text: name);

  final String id;
  final TextEditingController name;
  final String color;
  final String series;
  final String kind;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }
}

class _MemoryLayout extends PlatformTableLayoutNotifier {
  _MemoryLayout(super.tableKey, this.seed);
  final PlatformTableLayout seed;

  @override
  PlatformTableLayout build() {
    super.build();
    return seed;
  }

  @override
  void persist() {}
}

List<_Row> _rows() => [
  _Row('a', '双联开关面板', '白色', '80 系列', '自制'),
  _Row('b', '单联开关底座', '黑色', '80 系列', '采购'),
  _Row('c', '三联插座面板', '白色', '90 系列', '采购'),
  _Row('d', '双联开关底座', '黑色', '90 系列', '自制'),
];

List<EditableGridColumn<_Row>> _columns() => [
  EditableGridColumn(
    key: 'name',
    label: '货品名称',
    width: 210,
    required: true,
    headerInfo: '名称包含全部关键词',
    textOf: (row) => row.name.text,
    listenableOf: (row) => row.name,
    cellBuilder: (_, row) =>
        Text(row.name.text, key: ValueKey('name-${row.id}')),
  ),
  EditableGridColumn(
    key: 'color',
    label: '颜色',
    width: 130,
    filterValueOf: (row) => row.color,
    cellBuilder: (_, row) => Text(row.color),
  ),
  EditableGridColumn(
    key: 'series',
    label: '系列',
    width: 150,
    frozenTextOf: (row) => row.series,
    cellBuilder: (_, row) => Text(row.series),
  ),
  EditableGridColumn(
    key: 'kind',
    label: '类型',
    width: 120,
    filterValueOf: (row) => row.kind,
    cellBuilder: (_, row) => Text(row.kind),
  ),
];

Widget _page(
  UtenEditableGridController<_Row> rows, {
  String tableKey = 'editable-keywords',
  List<EditableGridColumn<_Row>>? columns,
  Widget Function(BuildContext, _Row)? details,
  bool editing = false,
  void Function(_Row row, int index)? onDelete,
}) => MaterialApp(
  home: Scaffold(
    body: ListView(
      children: [
        UtenEditableGrid<_Row>(
          controller: rows,
          tableKey: tableKey,
          showAddRow: editing,
          showRowDelete: editing,
          confirmDelete: false,
          onDeleteRow: onDelete,
          createBlankRow: editing ? () => _Row('new', '', '', '', '') : null,
          showColumnSettings: false,
          stickyHeader: false,
          rowDetailsBuilder: details,
          columns: columns ?? _columns(),
        ),
      ],
    ),
  ),
);

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(page);
  await tester.pumpAndSettle();
}

Finder _header(String label) => find.byWidgetPredicate(
  (widget) => widget is GridHeaderFilterCell && widget.label == label,
);
Finder get _input => find.byKey(const Key('uten-column-keyword-input'));
Finder get _search => find.byKey(const Key('uten-column-keyword-search'));

Future<void> _open(WidgetTester tester, String label) async {
  final header = _header(label).hitTestable();
  expect(header, findsOneWidget);
  await tester.tap(header);
  await tester.pumpAndSettle();
}

Future<void> _apply(
  WidgetTester tester,
  String label,
  String query, {
  bool enter = false,
}) async {
  await _open(tester, label);
  expect(_input, findsOneWidget);
  expect(tester.widget<TextField>(_input).decoration?.hintText, label);
  await tester.enterText(_input, query);
  if (enter) {
    await tester.testTextInput.receiveAction(TextInputAction.search);
  } else {
    await tester.tap(_search);
  }
  await tester.pumpAndSettle();
  expect(_input, findsNothing);
}

void _visibleIds(Iterable<String> visible, Iterable<String> hidden) {
  for (final id in visible) {
    expect(find.byKey(ValueKey('name-$id')), findsOneWidget);
  }
  for (final id in hidden) {
    expect(find.byKey(ValueKey('name-$id')), findsNothing);
  }
}

void main() {
  testWidgets(
    'filtered delete and insert operate on the owning source row rather than its visible position',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      await _pump(tester, _page(rows, editing: true));
      await _apply(tester, '货品名称', '单联');
      _visibleIds(['b'], ['a', 'c', 'd']);
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('name-b'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await pointer.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('在上方插入空行'));
      await tester.pumpAndSettle();
      expect(rows.rows.map((row) => row.id), ['a', 'new', 'b', 'c', 'd']);
      _visibleIds(['b'], ['a', 'c', 'd']);
      await tester.tap(find.byTooltip('删除该行').hitTestable());
      await tester.pumpAndSettle();
      expect(rows.rows.map((row) => row.id), ['a', 'new', 'c', 'd']);
      expect(rows.rows.first.name.text, '双联开关面板');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a host-owned filtered delete receives the real source index', (
    tester,
  ) async {
    final rows = UtenEditableGridController<_Row>(initial: _rows());
    addTearDown(rows.dispose);
    final deleted = <(String, int)>[];
    await _pump(
      tester,
      _page(
        rows,
        editing: true,
        onDelete: (row, index) => deleted.add((row.id, index)),
      ),
    );
    await _apply(tester, '货品名称', '单联');
    await tester.tap(find.byTooltip('删除该行').hitTestable());
    await tester.pumpAndSettle();
    expect(deleted, [('b', 1)]);
    expect(rows.rows.map((row) => row.id), ['a', 'b', 'c', 'd']);
  });

  testWidgets(
    'typing only narrows candidates; Enter applies every word to actual rows and preserves source ownership',
    (tester) async {
      final source = _rows();
      final rows = UtenEditableGridController<_Row>(initial: source);
      addTearDown(rows.dispose);
      await _pump(
        tester,
        _page(rows, details: (_, row) => Text('detail-${row.id}')),
      );

      await _open(tester, '货品名称');
      await tester.enterText(_input, '双联 开关');
      await tester.pump();
      _visibleIds(['a', 'b', 'c', 'd'], []);
      expect(find.text('双联开关面板（1）'), findsOneWidget);
      expect(find.text('单联开关底座（1）'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(_input, findsNothing);
      _visibleIds(['a', 'd'], ['b', 'c']);
      expect(find.text('detail-a'), findsOneWidget);
      expect(find.text('detail-b'), findsNothing);
      expect(rows.rows, orderedEquals(source));
      expect(rows.rows.map((row) => row.name.text), [
        '双联开关面板',
        '单联开关底座',
        '三联插座面板',
        '双联开关底座',
      ]);

      await _open(tester, '货品名称');
      expect(tester.widget<TextField>(_input).controller!.text, '双联 开关');
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      _visibleIds(['a', 'b', 'c', 'd'], []);
      expect(rows.rows, orderedEquals(source));
    },
  );

  testWidgets(
    'Search button intersects other keywords and exact facets, including the same column',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      await _pump(tester, _page(rows));
      await _apply(tester, '货品名称', '开关');
      await _apply(tester, '系列', '80');
      _visibleIds(['a', 'b'], ['c', 'd']);

      await _open(tester, '颜色');
      await tester.tap(find.text('白色（1）'));
      await tester.pumpAndSettle();
      _visibleIds(['a'], ['b', 'c', 'd']);
      await _apply(tester, '颜色', '黑');
      _visibleIds([], ['a', 'b', 'c', 'd']);
      expect(find.text('没有符合表头筛选条件的行'), findsOneWidget);
      await _open(tester, '颜色');
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      _visibleIds(['a', 'b'], ['c', 'd']);
      expect(rows.rows.length, 4);
    },
  );

  testWidgets(
    'candidate buckets intersect other exact and keyword columns while excluding their own committed condition',
    (tester) async {
      final source = [..._rows(), _Row('e', '', '黑色', '90 系列', '采购')];
      final rows = UtenEditableGridController<_Row>(initial: source);
      addTearDown(rows.dispose);
      await _pump(tester, _page(rows));
      await _open(tester, '颜色');
      await tester.tap(find.text('白色（2）'));
      await tester.pumpAndSettle();
      await _apply(tester, '系列', '90');
      _visibleIds(['c'], ['a', 'b', 'd', 'e']);

      await _open(tester, '货品名称');
      final header = tester.widget<GridHeaderFilterCell>(_header('货品名称'));
      expect(header.buckets.map((bucket) => (bucket.display, bucket.count)), [
        ('三联插座面板', 1),
      ]);
      expect(
        header.nullCount,
        0,
        reason:
            'the empty black goods row is outside the other-column intersection',
      );
      expect(find.text('三联插座面板（1）'), findsOneWidget);
      expect(find.text('双联开关面板（1）'), findsNothing);
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      await _apply(tester, '货品名称', '开关');
      _visibleIds([], ['a', 'b', 'c', 'd', 'e']);

      await _open(tester, '货品名称');
      expect(tester.widget<TextField>(_input).controller!.text, '开关');
      await tester.enterText(_input, '');
      await tester.pump();
      expect(
        find.text('三联插座面板（1）'),
        findsOneWidget,
        reason: 'this column must not filter its own candidate source',
      );
      _visibleIds([], ['a', 'b', 'c', 'd', 'e']);
      expect(tester.widget<GridHeaderFilterCell>(_header('颜色')).selected, '白色');
      await tester.enterText(_input, '插座');
      await tester.tap(_search);
      await tester.pumpAndSettle();
      _visibleIds(['c'], ['a', 'b', 'd', 'e']);
      expect(rows.rows, orderedEquals(source));
    },
  );

  testWidgets(
    'zero matches keep search and clearing reachable; editing a hidden row updates the projection',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      await _pump(tester, _page(rows));
      await _apply(tester, '货品名称', '不存在');
      _visibleIds([], ['a', 'b', 'c', 'd']);
      rows.rows[2].name.text = '不存在开关';
      await tester.pumpAndSettle();
      _visibleIds(['c'], ['a', 'b', 'd']);
      expect(rows.rows.length, 4);
      await _apply(tester, '货品名称', '');
      _visibleIds(['a', 'b', 'c', 'd'], []);
    },
  );

  testWidgets(
    'all candidates can be searched and only numeric measures submit conditions',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      final columns = [
        for (final (key, label, numeric) in [
          ('deliveryDate', '交期', false),
          ('quantity', '需求数量', true),
          ('amount', '金额', true),
          ('status', '状态', false),
        ])
          EditableGridColumn<_Row>(
            key: key,
            label: label,
            width: 160,
            numeric: numeric,
            textOf: (row) => row.id,
            filterValueOf: (row) => row.id,
            cellBuilder: (_, row) => Text('$key-${row.id}'),
          ),
        EditableGridColumn<_Row>(
          key: 'action',
          label: '操作',
          width: 100,
          cellBuilder: (_, row) => const Icon(Icons.edit),
        ),
      ];
      await _pump(tester, _page(rows, columns: columns));
      expect(find.byType(GridHeaderFilterCell), findsNWidgets(4));
      for (final label in ['交期', '需求数量', '金额', '状态']) {
        await _open(tester, label);
        expect(_input, findsOneWidget);
        expect(
          _search,
          label == '需求数量' || label == '金额' ? findsOneWidget : findsNothing,
        );
        expect(find.text('b（1）'), findsOneWidget);
        await tester.tap(find.text('所有'));
        await tester.pumpAndSettle();
      }
      expect(rows.rows.length, 4);
    },
  );

  testWidgets(
    'a textOf-only candidate is a real exact row filter and an edited obsolete value is cleared',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      await _pump(tester, _page(rows));
      await _open(tester, '货品名称');
      await tester.tap(find.text('单联开关底座（1）'));
      await tester.pumpAndSettle();
      _visibleIds(['b'], ['a', 'c', 'd']);
      rows.rows[1].name.text = '更新后的开关';
      await tester.pumpAndSettle();
      _visibleIds(['a', 'b', 'c', 'd'], []);
      expect(find.text('没有符合表头筛选条件的行'), findsNothing);
      expect(rows.rows[1].name.text, '更新后的开关');
      expect(rows.rows.length, 4);
    },
  );

  testWidgets(
    'controller and table changes close old menus, reject captured callbacks and do not transfer the previous query',
    (tester) async {
      final a = UtenEditableGridController<_Row>(initial: _rows());
      final b = UtenEditableGridController<_Row>(
        initial: [_Row('x', '新插座', '灰色', '100', '采购')],
      );
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await _pump(tester, _page(a));
      await _apply(tester, '货品名称', '开关');
      await _open(tester, '货品名称');
      final oldSubmit = tester.widget<TextField>(_input).onSubmitted!;
      final oldButton = tester
          .widget<UtenColumnSearchButton>(_search)
          .onPressed;
      final oldField = tester.widget<TextField>(_input).controller!;
      oldField.text = '不可继承';
      await tester.pumpWidget(_page(b));
      await tester.pumpAndSettle();
      expect(_input, findsNothing);
      oldSubmit('不可继承');
      oldButton();
      await tester.pumpAndSettle();
      _visibleIds(['x'], ['a', 'b', 'c', 'd']);
      await _open(tester, '货品名称');
      expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      await _apply(tester, '货品名称', '新');
      await tester.pumpWidget(_page(b, tableKey: 'different-table'));
      await tester.pumpAndSettle();
      await _open(tester, '货品名称');
      expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
      expect(a.rows.length, 4);
      expect(b.rows.single.id, 'x');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('old queries are ignored and new queries survive rebuild only', (
    tester,
  ) async {
    final rows = UtenEditableGridController<_Row>(initial: _rows());
    addTearDown(rows.dispose);
    const tableKey = 'editable-saved-keywords';
    final container = ProviderContainer(
      overrides: [
        authenticatedScopeProvider.overrideWithValue(null),
        apiBaseUrlProvider.overrideWithValue('https://test.invalid/api'),
        platformTableLayoutProvider(tableKey).overrideWith(
          () => _MemoryLayout(
            tableKey,
            const PlatformTableLayout(
              filters: {'search.name': '开关', 'color': '白色'},
              sortColumn: 'name',
              sortAscending: false,
              hasQueryPreferences: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await _pump(
      tester,
      UncontrolledProviderScope(
        container: container,
        child: _page(rows, tableKey: tableKey),
      ),
    );
    expect(find.byTooltip('名称包含全部关键词'), findsOneWidget);
    _visibleIds(['a', 'b', 'c', 'd'], []);
    await _apply(tester, '货品名称', '开关');
    await _open(tester, '颜色');
    await tester.tap(find.text('白色（1）'));
    await tester.pumpAndSettle();
    _visibleIds(['a'], ['b', 'c', 'd']);
    await _apply(tester, '系列', '80');
    final saved = container.read(platformTableLayoutProvider(tableKey));
    expect(saved.filters, isEmpty);
    expect(saved.sortColumn, 'name');
    expect(saved.sortAscending, isFalse);
    expect(rows.rows.map((row) => row.id), ['a', 'b', 'c', 'd']);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _page(rows, tableKey: tableKey),
      ),
    );
    await tester.pumpAndSettle();
    _visibleIds(['a'], ['b', 'c', 'd']);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _page(rows, tableKey: tableKey),
      ),
    );
    await tester.pumpAndSettle();
    _visibleIds(['a', 'b', 'c', 'd'], []);
    expect(
      container.read(platformTableLayoutProvider(tableKey)).sortColumn,
      'name',
    );
  });

  testWidgets(
    'IME composition does not submit an incomplete word or close the candidate menu',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      await _pump(tester, _page(rows));
      await _open(tester, '货品名称');
      final field = tester.widget<TextField>(_input);
      field.controller!.value = const TextEditingValue(
        text: 'kai',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      field.onSubmitted!('kai');
      await tester.pump();
      expect(_input, findsOneWidget);
      _visibleIds(['a', 'b', 'c', 'd'], []);
      field.controller!.value = const TextEditingValue(
        text: '开关',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.tap(_search);
      await tester.pumpAndSettle();
      expect(_input, findsNothing);
      _visibleIds(['a', 'b', 'd'], ['c']);
    },
  );

  testWidgets(
    'server ABA invalidates an already visible menu before rebuilding it',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      final server = StateProvider<String>((ref) => 'https://a.invalid/api');
      const tableKey = 'editable-owner-boundary';
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(server)),
          platformTableLayoutProvider(tableKey).overrideWith(
            () => _MemoryLayout(tableKey, const PlatformTableLayout()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await _pump(
        tester,
        UncontrolledProviderScope(
          container: container,
          child: _page(rows, tableKey: tableKey),
        ),
      );
      await _apply(tester, '货品名称', '开关');
      await _open(tester, '货品名称');
      final oldSubmit = tester.widget<TextField>(_input).onSubmitted!;
      final oldButton = tester
          .widget<UtenColumnSearchButton>(_search)
          .onPressed;
      tester.widget<TextField>(_input).controller!.text = '旧服务器词';
      container.read(server.notifier).state = 'https://b.invalid/api';
      expect(container.read(apiBaseUrlProvider), 'https://b.invalid/api');
      container.read(server.notifier).state = 'https://a.invalid/api';
      expect(container.read(apiBaseUrlProvider), 'https://a.invalid/api');
      // A restored URL is still a different lifecycle. These callbacks are from
      // the real previous menu, not a reconstructed test-only query callback.
      oldSubmit('旧服务器词');
      oldButton();
      await tester.pumpAndSettle();
      expect(_input, findsNothing);
      _visibleIds(['a', 'b', 'c', 'd'], []);
      expect(
        container.read(platformTableLayoutProvider(tableKey)).filters,
        isEmpty,
      );
      expect(rows.rows.length, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the same-row search action remains reachable in a narrow dark viewport at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final rows = UtenEditableGridController<_Row>(initial: _rows());
      addTearDown(rows.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                UtenEditableGrid<_Row>(
                  controller: rows,
                  columns: [_columns().first],
                  showAddRow: false,
                  showRowDelete: false,
                  showColumnSettings: false,
                  stickyHeader: false,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _open(tester, '货品名称');
      final input = tester.getRect(_input);
      final button = tester.getRect(_search);
      expect((input.center.dy - button.center.dy).abs(), lessThan(1));
      expect(button.right, lessThanOrEqualTo(390));
      expect(button.left, greaterThanOrEqualTo(0));
      expect(button.bottom, lessThanOrEqualTo(520));
      await tester.enterText(_input, '开关');
      await tester.tap(_search.hitTestable());
      await tester.pumpAndSettle();
      expect(_input, findsNothing);
      _visibleIds(['a', 'b', 'd'], ['c']);
      expect(tester.takeException(), isNull);
    },
  );
}
