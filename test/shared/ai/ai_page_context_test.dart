import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_color_name.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_filter_picker_field.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/ai/page_context/ai_page_context.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

final _zh = AppLocalizationsZh();

class _Task {
  const _Task(this.code, this.status);
  final String code;
  final String status;
}

class _Line extends EditableGridRow {
  _Line(this.code, {this.review});
  final String code;
  final qty = TextEditingController();
  final String? review;
  @override
  void dispose() {
    qty.dispose();
    super.dispose();
  }
}

Future<AiPageContextController> _pump(
  WidgetTester tester,
  Widget body, {
  Size size = const Size(1400, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = AiPageContextController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AiPageContextScope(controller: controller, child: child!),
      home: Scaffold(body: body),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

/// Registers like a shared component (AiPageSlot on its own context) and
/// counts dependency changes, to prove a capture adds no route dependency.
class _CountingField extends StatefulWidget {
  const _CountingField(this.label, this.changes);
  final String label;
  final List<int> changes;
  @override
  State<_CountingField> createState() => _CountingFieldState();
}

class _CountingFieldState extends State<_CountingField> {
  final _slot = AiPageSlot();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.changes.add(1);
    _slot.attach(
      context,
      AiFieldSource(capture: (_) => AiFieldSnapshot(label: widget.label)),
    );
  }

  @override
  void dispose() {
    _slot.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

Map<String, Object?> _snapshot(AiPageContextController controller) =>
    controller.capture(_zh).snapshot!;

List<Map<String, Object?>> _list(Object? raw) =>
    (raw as List).cast<Map<String, Object?>>();

MasterDataTableView<_Task> _taskTable(
  List<_Task> rows, {
  void Function(_Task)? onOpen,
  Color? Function(_Task)? rowColor,
}) => MasterDataTableView<_Task>(
  columns: [
    MasterColumnDef<_Task>(
      key: 'code',
      label: '货品编号',
      width: 160,
      value: (task) => task.code,
    ),
    MasterColumnDef<_Task>(
      key: 'status',
      label: '状态',
      width: 160,
      info: '按物料齐套和领料进度显示',
      filterFromRows: true,
      value: (task) => task.status,
      cellColor: (context, task) => switch (task.status) {
        '可开工' => UtenColors.success,
        '部分可领' => UtenColors.violet,
        _ => UtenColors.slate500,
      },
      legendOf: (task) => switch (task.status) {
        '可开工' => '材料齐了, 可以开工',
        '部分可领' => '部分物料可领, 去领料',
        _ => null,
      },
    ),
    MasterColumnDef<_Task>(
      key: 'cost',
      label: '成本单价',
      width: 120,
      value: (_) => '12.50',
    ),
  ],
  items: rows,
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
  onRowTap: onOpen,
  rowColor: rowColor,
);

void main() {
  test('colour names resolve shared tokens, dark overlays and hue buckets', () {
    expect(utenColorName(UtenColors.success), '绿');
    expect(utenColorName(UtenColors.warning), '琥珀');
    expect(utenColorName(UtenColors.warningBg), '黄');
    expect(utenColorName(UtenColors.violet), '紫');
    expect(utenColorName(UtenColors.teal400), '青');
    expect(utenColorName(UtenColors.slate500), '灰');
    expect(utenColorName(UtenColors.fuchsia), '品红');
    expect(utenColorName(UtenColors.error.withValues(alpha: 0.18)), '红');
    expect(utenNamedColor(UtenColors.info)!.tone, UtenStatusBadgeType.info);
    expect(utenColorName(const Color(0xFF00FF00)), '绿');
    expect(utenColorName(Colors.transparent), isNull);
    expect(UtenStatusBadgeType.violet.colorName, '紫');
    expect(UtenStatusBadgeType.accent.colorName, '青绿');
  });

  test('values are single-line, bounded and never carry identifiers', () {
    final long = 'x' * 200;
    expect(aiSnapshotValue(long)!.length, AiSnapshotLimits.value);
    expect(aiSnapshotValue('a\u0000b\nc\u202Ed'), 'a b cd');
    expect(
      aiSnapshotValue(
        'job 39a3c832-b0e5-4fe2-8040-7cb4247741b9 https://x.test/a',
      ),
      'job [编号] [链接]',
    );
    expect(aiSnapshotLabel('39a3c832-b0e5-4fe2-8040-7cb4247741b9'), isNull);
    expect(aiSnapshotLabel('www.evil.test'), isNull);
    expect(aiSnapshotLabel('  客户  '), '客户');
    expect(aiParseRowList('1,3,5-6', 6), [0, 2, 4, 5]);
    expect(aiParseRowList('7', 6), isNull);
    expect(aiParseRowList('a', 6), isNull);
  });

  testWidgets(
    'table snapshot carries visible columns, first rows, legend counts with meaning and withholds sensitive values',
    (tester) async {
      final tasks = [
        for (var i = 0; i < 6; i++) _Task('V5000$i', '可开工'),
        const _Task('V50006', '部分可领'),
        const _Task('V50007', '部分可领'),
        const _Task('V50008', '缺料'),
      ];
      final controller = await _pump(tester, _taskTable(tasks));
      final snapshot = _snapshot(controller);
      final table = _list(snapshot['tables']).single;
      expect(_list(table['columns']).map((c) => c['label']), [
        '货品编号',
        '状态',
        '成本单价',
      ]);
      expect(_list(table['columns'])[1]['info'], '按物料齐套和领料进度显示');
      expect(_list(table['columns'])[2]['sensitive'], isTrue);
      final rows = _list(table['rows']);
      expect(rows, hasLength(9));
      expect(rows.first['no'], 1);
      expect(rows.first['cells'], ['V50000', '可开工', '']);
      final legend = {
        for (final entry in _list(table['legend'])) entry['value']: entry,
      };
      expect(legend['可开工'], {
        'column': '状态',
        'value': '可开工',
        'color': '绿',
        'tone': 'success',
        'meaning': '材料齐了, 可以开工',
        'count': 6,
      });
      expect(legend['部分可领']!['color'], '紫');
      expect(legend['部分可领']!['count'], 2);
      expect(legend['缺料']!['color'], '灰');
      expect(legend['缺料']!.containsKey('meaning'), isFalse);
      expect(snapshot['withheld'], contains('成本单价'));
      expect(jsonEncode(snapshot), isNot(contains('12.50')));
      final capture = controller.capture(_zh);
      expect(capture.rows, 9);
      expect(capture.actions.keys, contains('filterTable'));
    },
  );

  testWidgets('generic table actions filter and open rows through the table', (
    tester,
  ) async {
    final opened = <String>[];
    final controller = await _pump(
      tester,
      _taskTable(const [
        _Task('A1', '可开工'),
        _Task('A2', '缺料'),
        _Task('A3', '可开工'),
      ], onOpen: (task) => opened.add(task.code)),
    );
    final actions = controller.actions(_zh);
    expect(actions.keys, containsAll(['filterTable', 'openRow']));
    await controller.run(_zh, controller.capture(_zh).binding, 'openRow', {
      'row': 2,
    });
    expect(opened, ['A2']);
    await actions['filterTable']!.handler(
      const AiActionCall({'column': '状态', 'value': '缺料'}),
    );
    await tester.pumpAndSettle();
    final rows = _list(_list(_snapshot(controller)['tables']).single['rows']);
    expect(rows.map((row) => (row['cells']! as List).first), ['A2']);
    await expectLater(
      actions['filterTable']!.handler(
        const AiActionCall({'column': '状态', 'value': '不存在'}),
      ),
      throwsA(isA<AiActionFailure>()),
    );
    // Row numbers are checked against the rows bound at capture time.
    await expectLater(
      controller.run(_zh, controller.capture(_zh).binding, 'openRow', {
        'row': 9,
      }),
      throwsA(isA<AiActionFailure>()),
    );
    expect(
      () => actions['openRow']!.checkedArgs({'row': 'two'}),
      throwsA(isA<AiActionFailure>()),
    );
  });

  testWidgets(
    'editable grid reports flagged rows, review reasons, red required frames and in-cell yellow hints',
    (tester) async {
      final grid = UtenEditableGridController<_Line>(
        initial: [
          _Line('V1', review: '标价为0, 要先做报价单交给财务定价'),
          _Line('V2'),
          _Line('V3'),
        ],
      );
      addTearDown(grid.dispose);
      grid.rows[1].flagged = true;
      grid.rows[0].qty.text = '5';
      grid.rows[2].qty.text = '8';
      final controller = await _pump(
        tester,
        ListView(
          children: [
            UtenEditableGrid<_Line>(
              controller: grid,
              createBlankRow: () => _Line('new'),
              columns: [
                EditableGridColumn<_Line>(
                  key: 'goods',
                  label: '货品',
                  width: 160,
                  textOf: (row) => row.code,
                  reviewReasonOf: (row) => row.review,
                  cellBuilder: (_, row) => Text(row.code),
                ),
                EditableGridColumn<_Line>(
                  key: 'qty',
                  label: '数量',
                  width: 160,
                  required: true,
                  frozenTextOf: (row) => row.qty.text,
                  cellBuilder: (_, row) => RequiredCellFrame(
                    listenable: row.qty,
                    isEmpty: () => row.qty.text.trim().isEmpty,
                    child: TextField(
                      controller: row.qty,
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          isDense: true,
                          helper: row.code == 'V3'
                              ? const UtenFieldMessage.autofill('按上次记录预填')
                              : null,
                        ),
                        autofilled: row.code == 'V3',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      final table = _list(_snapshot(controller)['tables']).single;
      final rows = _list(table['rows']);
      expect(rows.map((row) => row['no']), [1, 2, 3]);
      expect(rows[1]['flagged'], isTrue);
      final flagged = _list(table['flaggedCells']);
      expect(
        flagged,
        containsAll([
          {
            'rowNo': 1,
            'rowLabel': 'V1 5',
            'column': '货品',
            'value': 'V1',
            'state': 'REVIEW',
            'reason': '标价为0, 要先做报价单交给财务定价',
          },
          {'rowNo': 2, 'rowLabel': 'V2', 'state': 'FLAGGED'},
          {
            'rowNo': 2,
            'rowLabel': 'V2',
            'column': '数量',
            'value': '',
            'state': 'REQUIRED_EMPTY',
          },
          {
            'rowNo': 3,
            'rowLabel': 'V3 8',
            'column': '数量',
            'value': '8',
            'state': 'REVIEW',
            'reason': '按上次记录预填',
          },
        ]),
      );
      expect(controller.capture(_zh).flagged, flagged.length);
      // Typing fixes the red frame; the next capture reflects it.
      await tester.enterText(find.byType(TextField).at(1), '3');
      await tester.pump();
      final after = _list(
        _list(_snapshot(controller)['tables']).single['flaggedCells'],
      );
      expect(after.where((cell) => cell['state'] == 'REQUIRED_EMPTY'), isEmpty);
    },
  );

  testWidgets(
    'inputs register label, value and states; passwords never register; AI fill marks yellow',
    (tester) async {
      final customer = TextEditingController();
      final cost = TextEditingController(text: '88.8');
      final password = TextEditingController(text: 'secret-pass');
      addTearDown(customer.dispose);
      addTearDown(cost.dispose);
      addTearDown(password.dispose);
      String? currency = 'USD';
      final controller = await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              UtenInput(
                label: '客户',
                required: true,
                controller: customer,
                info: '选对客户, 核对结账条件',
              ),
              UtenInput(label: '成本单价', controller: cost),
              UtenInput(label: '登录密码', controller: password, isPassword: true),
              UtenDropdownField(
                label: '币种',
                value: currency,
                autofilled: true,
                warningMessage: '按客户上次的币种预填',
                items: const [
                  UtenDropdownItem(value: 'USD', label: 'USD'),
                  UtenDropdownItem(value: 'CNY', label: 'CNY'),
                ],
                onChanged: (value) => setState(() => currency = value),
              ),
            ],
          ),
        ),
      );
      final snapshot = _snapshot(controller);
      final fields = {
        for (final field in _list(snapshot['fields'])) field['label']: field,
      };
      expect(fields.keys, ['客户', '成本单价', '币种']);
      expect(fields['客户'], {
        'label': '客户',
        'value': '',
        'state': 'REQUIRED_EMPTY',
        'required': true,
        'info': '选对客户, 核对结账条件',
      });
      expect(fields['成本单价']!.containsKey('value'), isFalse);
      expect(snapshot['withheld'], contains('成本单价'));
      expect(fields['币种']!['state'], 'AUTOFILLED');
      expect(fields['币种']!['message'], '按客户上次的币种预填');
      expect(jsonEncode(snapshot), isNot(contains('secret-pass')));
      expect(jsonEncode(snapshot), isNot(contains('登录密码')));

      final setField = controller.actions(_zh)['setField']!;
      final options =
          ((setField.toJson()['params']! as Map)['properties'] as Map)['field']
              as Map;
      expect(options['enum'], ['客户', '币种']);
      await setField.handler(
        const AiActionCall({'field': '客户', 'value': 'SUNAS'}),
      );
      await setField.handler(
        const AiActionCall({'field': '币种', 'value': 'cny'}),
      );
      await tester.pumpAndSettle();
      expect(customer.text, 'SUNAS');
      expect(currency, 'CNY');
      final after = {
        for (final field in _list(_snapshot(controller)['fields']))
          field['label']: field,
      };
      expect(after['客户']!['state'], 'AUTOFILLED');
      expect(after['客户']!['message'], _zh.fieldAiFilledReview);
      expect(after['币种']!['message'], _zh.fieldAiFilledReview);
      await expectLater(
        setField.handler(const AiActionCall({'field': '币种', 'value': 'EUR'})),
        throwsA(isA<AiActionFailure>()),
      );
      // A user edit clears the AI marker.
      await tester.enterText(find.byType(TextFormField).first, 'SUNAS LTD');
      await tester.pump();
      final edited = _list(_snapshot(controller)['fields']).first;
      expect(edited['state'], 'NORMAL');
    },
  );

  testWidgets(
    'whole rows painted red are flagged rows; filter fields and notices are read',
    (tester) async {
      final controller = await _pump(
        tester,
        Column(
          children: [
            UtenFilterPickerField(label: '仓库', value: '成品仓', onTap: () {}),
            const UtenInlineNotice(title: '提醒', message: '有 1 张任务缺料'),
            Expanded(
              child: _taskTable(
                const [
                  _Task('A1', '可开工'),
                  _Task('A2', '缺料'),
                  _Task('A3', '可开工'),
                ],
                rowColor: (task) =>
                    task.status == '缺料' ? UtenColors.errorBg : null,
              ),
            ),
          ],
        ),
      );
      final snapshot = _snapshot(controller);
      final table = _list(snapshot['tables']).single;
      final rows = _list(table['rows']);
      expect(rows.map((row) => row['flagged'] == true), [false, true, false]);
      expect(_list(table['flaggedCells']), [
        {'rowNo': 2, 'rowLabel': 'A2 缺料', 'state': 'FLAGGED'},
      ]);
      expect(_list(snapshot['fields']).single, {
        'label': '仓库',
        'value': '成品仓',
        'state': 'NORMAL',
      });
      expect(_list(snapshot['notices']).single, {
        'kind': 'INLINE',
        'title': '提醒',
        'text': '有 1 张任务缺料',
      });
      expect(controller.capture(_zh).flagged, 1);
    },
  );

  testWidgets('only the top-most current route is captured', (tester) async {
    final controller = await _pump(
      tester,
      Builder(
        builder: (context) => Column(
          children: [
            const UtenInput(label: '底层字段'),
            const UtenStatusBadge(
              label: '待审核',
              type: UtenStatusBadgeType.warning,
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: UtenInput(label: '顶层字段')),
                ),
              ),
              child: const Text('open'),
            ),
          ],
        ),
      ),
    );
    var snapshot = _snapshot(controller);
    expect(_list(snapshot['fields']).single['label'], '底层字段');
    expect(_list(snapshot['badges']).single, {
      'label': '待审核',
      'tone': 'warning',
      'color': '黄',
      'count': 1,
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    snapshot = _snapshot(controller);
    expect(_list(snapshot['fields']).single['label'], '顶层字段');
    expect(_list(snapshot['badges']), isEmpty);
    Navigator.of(tester.element(find.text('顶层字段'))).pop();
    await tester.pumpAndSettle();
    expect(_list(_snapshot(controller)['fields']).single['label'], '底层字段');
  });

  testWidgets(
    'a translucent route on top wins, offstage subtrees are skipped, and a capture adds no route dependency',
    (tester) async {
      final changes = <int>[];
      final controller = await _pump(
        tester,
        Builder(
          builder: (context) => Column(
            children: [
              _CountingField('底层字段', changes),
              const Offstage(child: UtenInput(label: '隐藏分页字段')),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  useRootNavigator: false,
                  builder: (_) => const Dialog(
                    child: SizedBox(
                      width: 300,
                      child: UtenInput(label: '弹窗字段'),
                    ),
                  ),
                ),
                child: const Text('dialog'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('next')),
                  ),
                ),
                child: const Text('push'),
              ),
            ],
          ),
        ),
      );
      List<Object?> labels() => [
        for (final field in _list(_snapshot(controller)['fields']))
          field['label'],
      ];
      expect(labels(), ['底层字段']);
      final before = changes.length;
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      expect(labels(), ['弹窗字段']);
      Navigator.of(tester.element(find.text('弹窗字段'))).pop();
      await tester.pumpAndSettle();
      expect(labels(), ['底层字段']);
      // After several captures, covering and uncovering the page does not
      // rebuild registered components (no ModalRoute dependency was added).
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(controller.capture(_zh).snapshot, isNull);
      Navigator.of(tester.element(find.text('next'))).pop();
      await tester.pumpAndSettle();
      expect(changes.length, before);
      expect(labels(), ['底层字段']);
    },
  );

  testWidgets('large pages shrink to the byte budget and mark truncation', (
    tester,
  ) async {
    final tasks = [
      for (var i = 0; i < 400; i++) _Task('${'长编号' * 20}$i', '可开工'),
    ];
    final controller = await _pump(tester, _taskTable(tasks));
    final snapshot = _snapshot(controller);
    final bytes = utf8.encode(jsonEncode(snapshot)).length;
    expect(bytes, lessThanOrEqualTo(AiSnapshotLimits.maxBytes));
    final table = _list(snapshot['tables']).single;
    expect(_list(table['rows']).length, lessThanOrEqualTo(30));
    expect(table['truncated'], isTrue);
    expect(table['visibleRows'], 400);
    for (final row in _list(table['rows'])) {
      for (final cell in row['cells']! as List) {
        expect((cell as String).length, lessThanOrEqualTo(80));
      }
    }
    expect(_list(table['legend']).single['count'], 400);
  });

  testWidgets(
    'sales order grid sends recognition review reasons and marks AI-filled cells',
    (tester) async {
      final grid = UtenEditableGridController<SalesGridRow>(
        initial: [
          SalesGridRow(amountUsesDiscount: true)
            ..goods = const GoodsOption(id: 'g1', code: 'V50001', name: '右按钮'),
          SalesGridRow(amountUsesDiscount: true)
            ..goods = const GoodsOption(id: 'g3', code: 'V50003', name: '左按钮'),
        ],
      );
      addTearDown(grid.dispose);
      grid.rows[0].qty.text = '10';
      grid.rows[1].qty.text = '20';
      grid.rows[1].markAiReview('标价为0, 要先做报价单交给财务定价');
      final controller = await _pump(
        tester,
        ListView(
          children: [
            Builder(
              builder: (context) => UtenEditableGrid<SalesGridRow>(
                controller: grid,
                createBlankRow: () => SalesGridRow(amountUsesDiscount: true),
                columns: salesGridColumns(
                  context: context,
                  rows: grid.rows,
                  onPickGoods: (_) async {},
                  docType: SalesDocType.order,
                  colorEntries: const {},
                  unitEntries: const {},
                ),
              ),
            ),
          ],
        ),
        size: const Size(2400, 1000),
      );
      var flagged = _list(
        _list(_snapshot(controller)['tables']).single['flaggedCells'],
      );
      final review = flagged.firstWhere((cell) => cell['state'] == 'REVIEW');
      expect(review['rowNo'], 2);
      expect(review['column'], '货品名称');
      expect(review['value'], '左按钮');
      expect(review['reason'], '标价为0, 要先做报价单交给财务定价');

      // AI changes row 1 quantity: the cell turns yellow, the recognition
      // mark on row 2 is untouched, and the next capture reports the AI fill.
      grid.rows[0].applyAiValue('qty', '100');
      await tester.pumpAndSettle();
      expect(grid.rows[0].qty.text, '100');
      flagged = _list(
        _list(_snapshot(controller)['tables']).single['flaggedCells'],
      );
      expect(
        flagged,
        contains(
          equals({
            'rowNo': 1,
            'rowLabel': '右按钮 V50001',
            'column': '数量',
            'value': '100',
            'state': 'REVIEW',
            'reason': _zh.fieldAiFilledReview,
          }),
        ),
      );
      expect(grid.rows[1].aiReview, isNotNull);
      // A user edit is a review: the yellow AI marker goes away.
      grid.rows[0].qty.text = '90';
      await tester.pumpAndSettle();
      expect(grid.rows[0].aiFilledNotifier.value, isEmpty);
    },
  );

  testWidgets(
    'withheld values never leave through row labels, reasons, messages or credential fields',
    (tester) async {
      final grid = UtenEditableGridController<_Line>(
        initial: [
          _Line('V1', review: '金额 999.99 偏高'),
          _Line('V2'),
        ],
      );
      addTearDown(grid.dispose);
      grid.rows[1].flagged = true;
      final controller = await _pump(
        tester,
        ListView(
          children: [
            // A cost column moved to the front of a table with red rows.
            SizedBox(
              height: 300,
              child: MasterDataTableView<_Task>(
                columns: [
                  MasterColumnDef<_Task>(
                    key: 'unitCost',
                    label: '单件材料',
                    width: 120,
                    aiSensitive: true,
                    value: (_) => '12.3456',
                  ),
                  MasterColumnDef<_Task>(
                    key: 'code',
                    label: '货品编号',
                    width: 160,
                    value: (task) => task.code,
                  ),
                ],
                items: const [_Task('A1', '可开工')],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                rowColor: (_) => UtenColors.error,
              ),
            ),
            UtenEditableGrid<_Line>(
              controller: grid,
              createBlankRow: () => _Line('new'),
              columns: [
                EditableGridColumn<_Line>(
                  key: 'amount',
                  label: '金额',
                  width: 120,
                  aiSensitive: true,
                  textOf: (_) => '999.99',
                  reviewReasonOf: (row) => row.review,
                  cellBuilder: (_, _) => const Text('999.99'),
                ),
                EditableGridColumn<_Line>(
                  key: 'goods',
                  label: '货品',
                  width: 160,
                  textOf: (row) => row.code,
                  cellBuilder: (_, row) => Text(row.code),
                ),
              ],
            ),
            for (final field in const [
              AiFieldSnapshot(
                label: '信用额度',
                value: '50000',
                state: AiFieldState.warning,
                message: '超出信用额度 12,000',
                info: '额度 50000',
              ),
              AiFieldSnapshot(label: '应发合计', value: '123456.00'),
              AiFieldSnapshot(label: '新密码', value: 'hunter2'),
              AiFieldSnapshot(label: 'API Key', value: 'sk-live-1'),
            ])
              AiPageRegistrar(
                source: AiFieldSource(capture: (_) => field),
                child: SizedBox(height: 20, child: Text(field.label)),
              ),
          ],
        ),
      );
      final snapshot = _snapshot(controller);
      final encoded = jsonEncode(snapshot);
      for (final secret in [
        '12.3456',
        '999.99',
        '50000',
        '12,000',
        '123456',
        'hunter2',
        'sk-live',
        '新密码',
        'API Key',
      ]) {
        expect(encoded, isNot(contains(secret)), reason: secret);
      }
      final tables = _list(snapshot['tables']);
      final redRow = _list(tables.first['flaggedCells']).single;
      expect(redRow['rowLabel'], 'A1');
      final gridFlags = _list(tables.last['flaggedCells']);
      expect(gridFlags.firstWhere((cell) => cell['column'] == '金额'), {
        'rowNo': 1,
        'rowLabel': 'V1',
        'column': '金额',
        'state': 'REVIEW',
      });
      final fields = {
        for (final field in _list(snapshot['fields'])) field['label']: field,
      };
      expect(fields.keys, ['信用额度', '应发合计']);
      expect(fields['信用额度'], {
        'label': '信用额度',
        'sensitive': true,
        'state': 'WARNING',
      });
      expect(snapshot['withheld'], containsAll(['单件材料', '金额', '信用额度', '应发合计']));
    },
  );

  testWidgets(
    'badge labels are bounded like the server: empty ones are skipped, long ones cut, unknown tones dropped',
    (tester) async {
      final controller = await _pump(
        tester,
        Column(
          children: [
            for (final badge in [
              AiBadgeSource(label: 'K' * 60, tone: 'danger'),
              const AiBadgeSource(label: '   '),
              const AiBadgeSource(
                label: '待领料',
                tone: 'danger',
                color: '红',
                count: 3,
              ),
              const AiBadgeSource(
                label: '密钥不可读',
                tone: 'bogus',
                color: '非常长的颜色名称超过八个字',
              ),
            ])
              AiPageRegistrar(
                source: badge,
                child: const SizedBox(height: 10, width: 10),
              ),
          ],
        ),
      );
      final badges = _list(_snapshot(controller)['badges']);
      expect(badges, hasLength(3));
      expect(badges.first['label'], 'K' * AiSnapshotLimits.label);
      expect(badges[1], {
        'label': '待领料',
        'tone': 'danger',
        'color': '红',
        'count': 3,
      });
      expect(badges[2].containsKey('tone'), isFalse);
      expect((badges[2]['color']! as String).length, lessThanOrEqualTo(8));
    },
  );

  testWidgets(
    'a confirmed card runs only on the page instance and rows it was proposed for',
    (tester) async {
      final opened = <String>[];
      final rows = ValueNotifier(const [
        _Task('A1', '可开工'),
        _Task('A2', '缺料'),
        _Task('A3', '可开工'),
      ]);
      addTearDown(rows.dispose);
      final controller = await _pump(
        tester,
        ValueListenableBuilder<List<_Task>>(
          valueListenable: rows,
          builder: (_, value, _) =>
              _taskTable(value, onOpen: (task) => opened.add(task.code)),
        ),
      );
      final proposal = controller.capture(_zh).binding;
      expect(
        (_list(
          _snapshot(controller)['pageActions'],
        )).firstWhere((action) => action['name'] == 'openRow')['table'],
        1,
      );
      await controller.run(_zh, proposal, 'openRow', {'row': 2});
      expect(opened, ['A2']);
      // Sorted or reloaded in between: row 2 now holds another record.
      rows.value = const [
        _Task('A3', '可开工'),
        _Task('A1', '可开工'),
        _Task('A2', '缺料'),
      ];
      await tester.pumpAndSettle();
      await expectLater(
        controller.run(_zh, proposal, 'openRow', {'row': 2}),
        throwsA(
          isA<AiActionFailure>().having(
            (error) => error.message,
            'message',
            _zh.aiActionRowChanged(2),
          ),
        ),
      );
      await expectLater(
        controller.run(_zh, proposal, 'openRow', {'row': 9}),
        throwsA(
          isA<AiActionFailure>().having(
            (error) => error.message,
            'message',
            _zh.aiActionRowMissing(9),
          ),
        ),
      );
      expect(opened, ['A2']);
      final fresh = controller.capture(_zh).binding;
      await controller.run(_zh, fresh, 'openRow', {'row': 2});
      expect(opened, ['A2', 'A1']);
      // Another page instance of the same kind on top: the card does not run.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: _taskTable(const [
                _Task('B1', '可开工'),
                _Task('B2', '缺料'),
              ], onOpen: (task) => opened.add(task.code)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        controller.run(_zh, fresh, 'openRow', {'row': 2}),
        throwsA(
          isA<AiActionFailure>().having(
            (error) => error.message,
            'message',
            _zh.aiChatCardPageChanged,
          ),
        ),
      );
      expect(opened, ['A2', 'A1']);
      navigator.pop();
      await tester.pumpAndSettle();
      await controller.run(_zh, fresh, 'openRow', {'row': 2});
      expect(opened, ['A2', 'A1', 'A1']);
      await expectLater(
        controller.run(_zh, AiCaptureBinding.none, 'openRow', {'row': 2}),
        throwsA(isA<AiActionFailure>()),
      );
    },
  );

  test(
    'payroll, HR and personal pages are never read; credentials are dropped',
    () {
      for (final route in [
        '/payroll/review',
        '/payroll/slip/x1',
        '/hr/tasks',
        '/employee',
        '/employee/x1/edit',
        '/profile/edit',
        '/change-password',
        '/admin/permissions',
        '/admin/audit-logs',
      ]) {
        expect(aiPageContentWithheld(route), isTrue, reason: route);
      }
      for (final route in [
        '/sales/orders/new',
        '/payrolls',
        '/employees-board',
      ]) {
        expect(aiPageContentWithheld(route), isFalse, reason: route);
      }
      // ADR-153: system administration and security pages are protected.
      for (final route in [
        '/admin/permissions',
        '/admin/audit-logs',
        '/admin/system-settings',
        '/admin/server-status',
        '/admin/ai-settings',
        '/page-permissions/sales_orders',
        '/security/blacklist',
        '/settings/device-receipts',
        // A3 red team: letter case and doubled slashes are the same page.
        '/ADMIN/system-settings',
        '/Admin/ai-settings',
        '//admin/ai-settings',
        '/admin/ai-settings/',
      ]) {
        expect(aiPageProtected(route), isTrue, reason: route);
        expect(aiPageContentWithheld(route), isTrue, reason: route);
      }
      for (final route in [
        '/payroll/review',
        '/settings',
        '/administration-notes',
        '/warehouse/stock',
      ]) {
        expect(aiPageProtected(route), isFalse, reason: route);
      }
      for (final label in [
        '应发',
        '实发合计',
        '扣减',
        '个税',
        '身份证号',
        '银行账号',
        '手机',
        '成本单价',
        // A3 red team: spaced, full-width and purchase-price synonyms.
        '成 本',
        '\uFF23\uFF4F\uFF53\uFF54',
        '毛 利',
        '进货价',
        '进价',
      ]) {
        expect(aiIsSensitiveLabel(label), isTrue, reason: label);
      }
      for (final label in ['登录密码', '验证码', 'API Key', 'Access Token']) {
        expect(aiIsCredentialLabel(label), isTrue, reason: label);
      }
      for (final label in ['数量', '货品', '输入 token 用量']) {
        expect(aiIsCredentialLabel(label), isFalse, reason: label);
      }
    },
  );
}
