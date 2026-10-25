import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _tableKey = 'required-leading-regression';

class _SavedLayout extends PlatformTableLayoutNotifier {
  _SavedLayout(super.tableKey, this.seed);
  final PlatformTableLayout seed;
  @override
  PlatformTableLayout build() {
    super.build();
    return seed;
  }

  @override
  void persist() {}
}

const _oldLayout = PlatformTableLayout(
  order: ['billNo', 'amount', 'remark', 'status', 'date'],
  hidden: {'status', 'remark'},
  pinned: {'amount'},
  widths: {'billNo': 240, 'amount': 185},
  filters: {'billNo': 'DOC-1'},
  sortColumn: 'billNo',
  sortAscending: false,
  hasQueryPreferences: true,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<String> required = const ['status'],
  PlatformTableLayout seed = _oldLayout,
  List<MapEntry<String, String?>>? filters,
  ValueNotifier<List<String>>? temporary,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWithValue(null),
      apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
      platformTableLayoutProvider(
        _tableKey,
      ).overrideWith(() => _SavedLayout(_tableKey, seed)),
    ],
  );
  addTearDown(container.dispose);
  final temporaryKeys = temporary ?? ValueNotifier<List<String>>(const []);
  if (temporary == null) addTearDown(temporaryKeys.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 820,
            height: 480,
            child: ValueListenableBuilder<List<String>>(
              valueListenable: temporaryKeys,
              builder: (context, keys, child) => MasterDataTableView<String>(
                tableKey: _tableKey,
                requiredLeadingColumnKeys: required,
                temporaryLeadingColumnKeys: keys,
                columns: [
                  for (final field in const [
                    ('billNo', '单号'),
                    ('amount', '金额'),
                    ('status', '状态'),
                    ('remark', '备注'),
                    ('date', '日期'),
                  ])
                    MasterColumnDef(
                      key: field.$1,
                      label: field.$2,
                      width: 160,
                      sortable: field.$1 == 'billNo',
                      value: (_) => '${field.$1}-value',
                    ),
                ],
                items: const ['row-1'],
                facets: const {
                  'billNo': [
                    MasterFacetBucket(value: 'DOC-1', label: 'DOC-1', count: 1),
                  ],
                },
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (key, value) =>
                    filters?.add(MapEntry(key, value)),
                onSortChange: (_, _) {},
                selectable: true,
                idOf: (row) => row,
                onSelectedIdsChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _header(String label) => find.text(label).hitTestable().first;
double _x(WidgetTester tester, String label) =>
    tester.getTopLeft(_header(label)).dx;

Future<void> _rightClick(WidgetTester tester, String label) async {
  final gesture = await tester.startGesture(
    tester.getCenter(_header(label)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('临时必填前置在退出后恢复原显隐列序和固定，表格状态不重挂', (tester) async {
    final temporary = ValueNotifier<List<String>>(const []);
    addTearDown(temporary.dispose);
    final container = await _pump(
      tester,
      required: const [],
      temporary: temporary,
    );
    final table = find.byType(MasterDataTableView<String>);
    final state = tester.state(table);
    expect(find.text('状态'), findsNothing);
    expect(_x(tester, '金额'), lessThan(_x(tester, '单号')));

    temporary.value = const ['status', 'remark'];
    await tester.pumpAndSettle();
    expect(_x(tester, '状态'), lessThan(_x(tester, '备注')));
    expect(_x(tester, '备注'), lessThan(_x(tester, '金额')));
    final stored = container.read(platformTableLayoutProvider(_tableKey));
    expect(stored.order, _oldLayout.order);
    expect(stored.hidden, _oldLayout.hidden);
    expect(stored.pinned, _oldLayout.pinned);

    temporary.value = const [];
    await tester.pumpAndSettle();
    expect(tester.state(table), same(state));
    expect(find.text('状态'), findsNothing);
    expect(find.text('备注'), findsNothing);
    expect(_x(tester, '金额'), lessThan(_x(tester, '单号')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑期间普通列的布局操作不会保存临时必填列的显示和固定', (tester) async {
    final temporary = ValueNotifier<List<String>>(const ['status', 'remark']);
    addTearDown(temporary.dispose);
    final container = await _pump(
      tester,
      required: const [],
      temporary: temporary,
    );
    UtenColumnChooserButton chooser() => tester.widget<UtenColumnChooserButton>(
      find.byType(UtenColumnChooserButton).hitTestable().first,
    );
    chooser().onToggle('status');
    expect(
      container.read(platformTableLayoutProvider(_tableKey)).hidden,
      _oldLayout.hidden,
    );
    final order = chooser().order!;
    chooser().onReorder!(order.indexOf('date'), 0);
    await tester.pumpAndSettle();
    chooser().onToggle('billNo');
    await tester.pumpAndSettle();
    final stored = container.read(platformTableLayoutProvider(_tableKey));
    expect(stored.hidden, {'status', 'remark', 'billNo'});
    expect(stored.pinned, {'amount'});
    expect(
      stored.order.indexOf('status'),
      greaterThan(stored.order.indexOf('amount')),
    );
    expect(stored.widths, _oldLayout.widths);

    temporary.value = const [];
    await tester.pumpAndSettle();
    expect(find.text('状态'), findsNothing);
    expect(find.text('备注'), findsNothing);
    expect(find.text('单号'), findsNothing);
    expect(_x(tester, '金额'), lessThan(_x(tester, '日期')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('临时必填列全屏仍前置，全不选不会泄露临时显隐到保存布局', (tester) async {
    final temporary = ValueNotifier<List<String>>(const ['status', 'remark']);
    addTearDown(temporary.dispose);
    final container = await _pump(
      tester,
      required: const [],
      temporary: temporary,
    );
    await tester.tap(find.text('全屏'));
    await tester.pumpAndSettle();
    expect(_x(tester, '状态'), lessThan(_x(tester, '备注')));
    final chooser = tester.widget<UtenColumnChooserButton>(
      find.byType(UtenColumnChooserButton).hitTestable().first,
    );
    chooser.onToggleAll(false);
    await tester.pumpAndSettle();
    expect(find.text('状态').hitTestable(), findsOneWidget);
    expect(find.text('备注').hitTestable(), findsOneWidget);
    final stored = container.read(platformTableLayoutProvider(_tableKey));
    expect(stored.hidden, containsAll(['status', 'remark']));
    expect(stored.pinned, isNot(contains('status')));
    expect(stored.pinned, isNot(contains('remark')));
    expect(stored.hidden, isNot(contains('billNo')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧布局隐藏后置状态仍恢复前导，保留其它布局与查询偏好', (tester) async {
    final filters = <MapEntry<String, String?>>[];
    final container = await _pump(tester, filters: filters);
    expect(_x(tester, '状态'), lessThan(_x(tester, '金额')));
    expect(_x(tester, '金额'), lessThan(_x(tester, '单号')));
    expect(find.text('备注'), findsNothing);
    expect(
      filters.any((entry) => entry.key == 'billNo' && entry.value == 'DOC-1'),
      isFalse,
    );
    final stored = container.read(platformTableLayoutProvider(_tableKey));
    expect(stored.widths, _oldLayout.widths);
    expect(stored.filters, _oldLayout.filters);
    expect(stored.sortColumn, 'billNo');
    expect(stored.sortAscending, isFalse);
    final checkboxX = tester
        .getTopLeft(find.byType(Checkbox).hitTestable().first)
        .dx;
    expect(_x(tester, '状态'), greaterThan(checkboxX));
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有 opt-in 的页面照旧恢复隐藏状态和个人固定列', (tester) async {
    await _pump(tester, required: const []);
    expect(find.text('状态'), findsNothing);
    expect(find.text('备注'), findsNothing);
    expect(_x(tester, '金额'), lessThan(_x(tester, '单号')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('required 状态拒绝拖隐、拖移和取消固定，普通列仍可隐藏', (tester) async {
    await _pump(tester);
    await tester.drag(_header('状态'), const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(find.text('状态').hitTestable(), findsOneWidget);
    await tester.drag(_header('状态'), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(_x(tester, '状态'), lessThan(_x(tester, '金额')));
    await _rightClick(tester, '状态');
    for (final label in ['取消固定', '隐藏此列', '放到最后']) {
      final ink = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(ink).onTap, isNull);
    }
    await tester.tapAt(const Offset(1100, 750));
    await tester.pumpAndSettle();
    await _rightClick(tester, '单号');
    await tester.tap(find.text('隐藏此列'));
    await tester.pumpAndSettle();
    expect(find.text('单号'), findsNothing);
    expect(find.text('状态').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏保留required前导列，表头设置也不能隐藏它', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('全屏'));
    await tester.pumpAndSettle();
    expect(_x(tester, '状态'), lessThan(_x(tester, '金额')));
    final chooser = tester.widget<UtenColumnChooserButton>(
      find.byType(UtenColumnChooserButton).hitTestable().first,
    );
    expect(
      chooser.entries.singleWhere((entry) => entry.key == 'status').required,
      isTrue,
    );
    chooser.onToggle('status');
    chooser.onToggleAll(false);
    await tester.pumpAndSettle();
    expect(find.text('状态').hitTestable(), findsOneWidget);
    expect(find.text('金额').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
