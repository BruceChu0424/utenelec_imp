import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'dart:ui' show PointerDeviceKind;
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/search/numeric_column_query.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import '../support/field_hint_support.dart';

class _Row extends EditableGridRow {
  _Row(this.id, this.exact);
  final String id;
  final String? exact;
}

const _inputKey = Key('uten-column-keyword-input');

Future<void> _open(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).hitTestable().first);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(_inputKey), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

Widget _master({
  bool paged = false,
  bool remote = false,
  ValueChanged<(String, String?)>? changed,
  TargetPlatform? platform,
  double textScale = 1,
}) => MaterialApp(
  theme: platform == null
      ? null
      : buildLightTheme().copyWith(platform: platform),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: MasterDataTableView<_Row>(
      columns: [
        MasterColumnDef(key: 'id', label: '单号', width: 100, value: (r) => r.id),
        MasterColumnDef(
          key: 'differenceQty',
          label: '差异数',
          width: 170,
          type: 'number',
          sortable: true,
          filterFromRows: !paged,
          columnSearchEnabled: remote ? true : null,
          value: (r) => r.exact == null ? '—' : '${r.exact} 米',
          exactValueOf: (r) => r.exact,
        ),
      ],
      items: [
        _Row('A', '-2.000000000000000001'),
        _Row('B', '0'),
        _Row('C', '2'),
        _Row('U', null),
      ],
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onPageChange: paged ? (_) async {} : null,
      serverColumnSearchKeys: remote ? const {'differenceQty'} : const {},
      onFilterChanged: (key, value) => changed?.call((key, value)),
    ),
  ),
);

void main() {
  for (final editor in [false, true]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        '${editor ? 'grid' : 'read table'} compact desktop search field and filled action share height at text scale $textScale',
        (tester) async {
          String? submitted;
          await tester.pumpWidget(
            editor
                ? MaterialApp(
                    theme: buildLightTheme().copyWith(
                      platform: TargetPlatform.windows,
                    ),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(textScale)),
                      child: child!,
                    ),
                    home: Scaffold(
                      body: Center(
                        child: SizedBox(
                          width: 180,
                          child: GridHeaderFilterCell(
                            label: '差异数',
                            buckets: const [],
                            nullCount: 0,
                            selected: null,
                            onChanged: (_) {},
                            onSearch: (value) => submitted = value,
                            numericSearch: true,
                          ),
                        ),
                      ),
                    ),
                  )
                : _master(
                    platform: TargetPlatform.windows,
                    textScale: textScale,
                  ),
          );
          await _open(tester, '差异数');
          final input = tester.getRect(find.byKey(_inputKey));
          final button = find.byKey(const Key('uten-column-keyword-search'));
          expect(tester.getRect(button).height, closeTo(input.height, .1));
          final editable = find.descendant(
            of: find.byKey(_inputKey),
            matching: find.byType(EditableText),
          );
          final container = InputDecorator.containerOf(
            tester.element(editable),
          )!;
          final painted = container.localToGlobal(Offset.zero) & container.size;
          expect(painted.height, closeTo(tester.getRect(button).height, .1));
          expect(painted.top, closeTo(tester.getRect(button).top, .1));
          if (textScale == 1) expect(input.height, 36);
          final action = tester.widget<UtenButton>(
            find.descendant(of: button, matching: find.byType(UtenButton)),
          );
          expect(action.type, UtenButtonType.primary);
          await tester.enterText(find.byKey(_inputKey), '>=0');
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(find.byKey(_inputKey), findsNothing);
          if (editor) expect(submitted, '>=0');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'an open header menu follows painted scroll movement and retains pending input without idle frames',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  const SizedBox(height: 150),
                  SizedBox(
                    width: 180,
                    child: GridHeaderFilterCell(
                      label: '名称',
                      buckets: const [],
                      nullCount: 0,
                      selected: null,
                      onChanged: (_) {},
                      onSearch: (_) {},
                    ),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        ),
      );
      await _open(tester, '名称');
      await tester.enterText(find.byKey(_inputKey), '尚未提交');
      final before = tester.getRect(
        find.byKey(const Key('uten-table-header-menu')),
      );
      final controller = tester
          .widget<TextField>(find.byKey(_inputKey))
          .controller;
      scroll.jumpTo(100);
      await tester.pumpAndSettle();
      final after = tester.getRect(
        find.byKey(const Key('uten-table-header-menu')),
      );
      expect(after.top, closeTo(before.top - 100, .1));
      expect(
        identical(
          tester.widget<TextField>(find.byKey(_inputKey)).controller,
          controller,
        ),
        isTrue,
      );
      expect(controller!.text, '尚未提交');
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
  for (final grid in [false, true]) {
    testWidgets(
      '${grid ? 'grid' : 'read table'} search guidance is revealed by hover and never reserves a helper paragraph',
      (tester) async {
        await tester.pumpWidget(
          grid
              ? MaterialApp(
                  home: Scaffold(
                    body: Center(
                      child: SizedBox(
                        width: 180,
                        child: GridHeaderFilterCell(
                          label: '差异数',
                          buckets: const [],
                          nullCount: 0,
                          selected: null,
                          onChanged: (_) {},
                          onSearch: (_) {},
                          numericSearch: true,
                        ),
                      ),
                    ),
                  ),
                )
              : _master(),
        );
        await _open(tester, '差异数');
        final field = tester.widget<TextField>(find.byKey(_inputKey));
        expect(field.decoration!.helperText, isNull);
        expect(field.decoration!.prefixIcon, isNull);
        expect(find.text(NumericColumnQuery.help), findsNothing);
        final icon = find.byKey(const Key('uten-column-search-help'));
        expect(icon, findsOneWidget);
        expect(
          find.descendant(of: find.byKey(_inputKey), matching: icon),
          findsOneWidget,
        );
        final inputRect = tester.getRect(find.byKey(_inputKey)),
            hintRect = tester.getRect(icon);
        expect(hintRect.right, lessThanOrEqualTo(inputRect.right + .1));
        expect(hintRect.left, greaterThan(inputRect.center.dx));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(icon));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.text(NumericColumnQuery.help), findsOneWidget);
        expect(find.byKey(_inputKey), findsOneWidget);
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
  test('numeric conditions retain decimal precision and unknown values', () {
    expect(
      NumericColumnQuery.tryParse(
        '>9007199254740992',
      )!.matches('9007199254740993'),
      isTrue,
    );
    expect(
      NumericColumnQuery.tryParse(
        '=-0.000000000000000001',
      )!.matches('-0.0000000000000000010'),
      isTrue,
    );
    expect(NumericColumnQuery.tryParse('-2..+3')!.matches('-2.000'), isTrue);
    expect(NumericColumnQuery.tryParse('-2..3')!.matches('3'), isTrue);
    expect(
      NumericColumnQuery.tryParse('-2..3')!.matches('3.000000000000000001'),
      isFalse,
    );
    expect(NumericColumnQuery.tryParse('!=0')!.matches(null), isFalse);
    for (final bad in [
      '1..-1',
      '1e2',
      'NaN',
      '1 OR 1=1',
      '>2 kg',
      '1..2..3',
      '.',
      '9' * 129,
    ]) {
      expect(NumericColumnQuery.tryParse(bad), isNull, reason: bad);
    }
    expect(displayedColumnDecimal('1,234.50 米'), '1234.50');
    expect(displayedColumnDecimal('≈12 kg'), isNull);
    expect(displayedColumnDecimal('12 米 / 2 件'), isNull);
  });

  testWidgets(
    'numeric local query filters complete rows and invalid input remains editable',
    (tester) async {
      await tester.pumpWidget(_master());
      await tester.pumpAndSettle();
      await _open(tester, '差异数');
      expect(
        tester.getTopLeft(find.byKey(_inputKey)).dy,
        lessThan(tester.getTopLeft(find.text('取消排序')).dy),
      );
      await _submit(tester, '<');
      await readFieldHint(tester, NumericColumnQuery.error);
      expect(find.text('A'), findsOneWidget);
      await _submit(tester, '<0');
      expect(find.text('A'), findsOneWidget);
      for (final id in ['B', 'C', 'U']) {
        expect(find.text(id), findsNothing);
      }
      await _open(tester, '差异数：<0');
      await _submit(tester, '-2..2');
      expect(
        find.text('A'),
        findsNothing,
        reason: 'A is strictly less than -2 at its recorded precision',
      );
      expect(find.text('B'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      await _open(tester, '差异数：-2..2');
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      expect(find.text('U'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial pages do not advertise local data search; per-column server query is explicit',
    (tester) async {
      await tester.pumpWidget(_master(paged: true));
      await tester.pumpAndSettle();
      await _open(tester, '差异数');
      expect(find.byKey(_inputKey), findsNothing);
      await tester.tap(find.text('取消排序'));
      final changes = <(String, String?)>[];
      await tester.pumpWidget(
        _master(paged: true, remote: true, changed: changes.add),
      );
      await tester.pumpAndSettle();
      await _open(tester, '差异数');
      await _submit(tester, '>=0');
      expect(changes, [('search.differenceQty', '>=0')]);
      expect(
        find.text('A'),
        findsOneWidget,
        reason:
            'Only the authoritative server response may change a partial page',
      );
      await _open(tester, '单号');
      expect(find.byKey(_inputKey), findsNothing);
    },
  );

  testWidgets(
    'exact numeric sorting distinguishes values beyond binary precision and keeps unknown last',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<_Row>(
              columns: [
                MasterColumnDef(
                  key: 'id',
                  label: '编号',
                  width: 100,
                  value: (r) => r.id,
                ),
                MasterColumnDef(
                  key: 'amount',
                  label: '金额',
                  width: 180,
                  type: 'money',
                  sortable: true,
                  value: (_) => '9,007,199,254,740,992.00',
                  exactValueOf: (r) => r.exact,
                ),
              ],
              items: [
                _Row('L', '9007199254740992'),
                _Row('H', '9007199254740993'),
                _Row('U', null),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _open(tester, '金额');
      await tester.tap(find.text('从大到小'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('H')).dy,
        lessThan(tester.getTopLeft(find.text('L')).dy),
      );
      expect(
        tester.getTopLeft(find.text('L')).dy,
        lessThan(tester.getTopLeft(find.text('U')).dy),
      );
    },
  );

  testWidgets(
    'editable numeric filtering preserves source identity and exposes empty candidates',
    (tester) async {
      final a = _Row('A', '-1');
      final b = _Row('B', '2');
      final u = _Row('U', null);
      final controller = UtenEditableGridController<_Row>(initial: [a, b, u]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                UtenEditableGrid<_Row>(
                  controller: controller,
                  showAddRow: false,
                  showRowDelete: false,
                  showColumnSettings: false,
                  columns: [
                    EditableGridColumn(
                      key: 'id',
                      label: '单号',
                      width: 90,
                      textOf: (r) => r.id,
                      cellBuilder: (_, r) => Text(r.id),
                    ),
                    EditableGridColumn(
                      key: 'difference',
                      label: '差异数',
                      width: 190,
                      numeric: true,
                      exactValueOf: (r) => r.exact,
                      textOf: (r) => r.exact ?? '',
                      cellBuilder: (_, r) => Text(r.exact ?? '—'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _open(tester, '差异数');
      await _submit(tester, '!=0');
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('U'), findsNothing);
      expect(controller.rows, [same(a), same(b), same(u)]);
      await _open(tester, '差异数：!=0');
      await tester.tap(find.text('其他（1）'));
      await tester.pumpAndSettle();
      // Selecting a precise bucket replaces the column condition.
      expect(find.text('U'), findsOneWidget);
      expect(find.text('A'), findsNothing);
      expect(controller.rows, [same(a), same(b), same(u)]);
    },
  );

  for (final editor in [false, true]) {
    for (final zoom in [0.85, 1.3, 2.0]) {
      testWidgets(
        '${editor ? 'grid' : 'master'} uses overlay canvas coordinates at app zoom $zoom',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(600, 500);
          tester.view.viewInsets = const FakeViewPadding(bottom: 120);
          addTearDown(tester.view.reset);
          final controller = UtenEditableGridController<_Row>(
            initial: [_Row('A', '1')],
          );
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) =>
                  UtenDisplayZoomBox(fontFactor: zoom, child: child!),
              home: Scaffold(
                body: editor
                    ? ListView(
                        children: [
                          UtenEditableGrid<_Row>(
                            controller: controller,
                            showAddRow: false,
                            showRowDelete: false,
                            showColumnSettings: false,
                            columns: [
                              EditableGridColumn(
                                key: 'status',
                                label: '状态',
                                width: 180,
                                filterValueOf: (_) => '已完成',
                                cellBuilder: (_, _) => const Text('已完成'),
                              ),
                            ],
                          ),
                        ],
                      )
                    : MasterDataTableView<String>(
                        columns: [
                          MasterColumnDef(
                            key: 'status',
                            label: '状态',
                            width: 180,
                            value: (r) => r,
                          ),
                        ],
                        items: const ['已完成'],
                        facets: const {
                          'status': [MasterFacetBucket(value: '已完成', count: 1)],
                        },
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _open(tester, '状态');
          final rect = tester.getRect(
            find.byKey(const Key('uten-table-header-menu')),
          );
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(600));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(380));
          await tester.enterText(find.byKey(_inputKey), '完成');
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '${editor ? 'grid' : 'master'} menu adapts while open to resize, keyboard and 200 percent text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(700, 700);
        addTearDown(tester.view.reset);
        final controller = UtenEditableGridController<_Row>(
          initial: [_Row('A', '1')],
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: editor
                  ? ListView(
                      children: [
                        UtenEditableGrid<_Row>(
                          controller: controller,
                          showAddRow: false,
                          showRowDelete: false,
                          showColumnSettings: false,
                          columns: [
                            EditableGridColumn(
                              key: 'status',
                              label: '状态',
                              width: 200,
                              filterValueOf: (_) => '已完成',
                              cellBuilder: (_, _) => const Text('已完成'),
                            ),
                          ],
                        ),
                      ],
                    )
                  : MasterDataTableView<String>(
                      columns: [
                        MasterColumnDef(
                          key: 'status',
                          label: '状态',
                          width: 200,
                          value: (r) => r,
                        ),
                      ],
                      items: const ['已完成'],
                      facets: const {
                        'status': [MasterFacetBucket(value: '已完成', count: 1)],
                      },
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _open(tester, '状态');
        tester.view.physicalSize = const Size(300, 400);
        tester.view.viewInsets = const FakeViewPadding(bottom: 190);
        await tester.pumpAndSettle();
        final rect = tester.getRect(
          find.byKey(const Key('uten-table-header-menu')),
        );
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(300));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(210));
        expect(find.byKey(_inputKey), findsOneWidget);
        await tester.enterText(find.byKey(_inputKey), '完成');
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
