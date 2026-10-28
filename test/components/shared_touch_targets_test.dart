import '../support/table_cell_geometry.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/outbound_weight_entry.dart';
import 'package:uten_imp/features/warehouse/widgets/outbound_weight_columns.dart';
import 'package:uten_imp/shared/attachments/attachment_category_control.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_grid_column.dart';
import 'package:uten_imp/shared/pricing/line_pricing_amount_cell.dart';
import 'package:uten_imp/shared/pricing/line_pricing_controller.dart';
import 'package:uten_imp/shared/widgets/reviewed_grid_columns.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

class _Row extends EditableGridRow {
  final weight = WeightEntryController(kg: 12.3456);
  final text = TextEditingController(text: '实称重量12345');

  @override
  void dispose() {
    weight.dispose();
    text.dispose();
    super.dispose();
  }
}

class _RetryNames extends Fake implements FinanceNameService {
  int retries = 0;
  @override
  List<DepartmentNode>? get departmentTree => null;
  @override
  String? get departmentLoadError => '加载失败';
  @override
  String department(String? id, {String? referencedName}) =>
      referencedName ?? id ?? '';
  @override
  Future<void> ensureDepartmentsLoaded() async => retries++;
}

Future<void> _pump(
  WidgetTester tester,
  double factor,
  Widget child, {
  TextScaler scaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.attachmentUpload,
        }),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, routed) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: UtenDisplayZoomBox(
            fontFactor: factor,
            child: UtenControlTheme(child: routed!),
          ),
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<Rect> _touchTarget(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final rect = tester.getRect(finder);
  expect(rect.width, greaterThanOrEqualTo(48 - 1e-6));
  expect(rect.height, greaterThanOrEqualTo(48 - 1e-6));
  return rect;
}

void main() {
  test(
    'reviewed grid cloning preserves explicit text-search policy and exact facets',
    () {
      for (final enabled in [false, true]) {
        final original = EditableGridColumn<_Row>(
          key: enabled ? 'result' : 'name',
          label: enabled ? '判定类型' : '货品名称',
          width: 160,
          textOf: (row) => row.text.text,
          filterValueOf: (row) => row.text.text,
          columnSearchEnabled: enabled,
          cellBuilder: (_, _) => const SizedBox.shrink(),
        );
        final reviewed = reviewedGridColumns<_Row>(
          columns: [original],
          baseline: const {},
          valuesOf: (_) => const {},
          listenableOf: (row) => row.text,
          editableKeys: const {},
          keyPrefix: 'search-policy-review',
        ).single;
        expect(reviewed.columnSearchEnabled, enabled);
        expect(reviewed.supportsKeywordSearch, enabled);
        expect(reviewed.filterValueOf, same(original.filterValueOf));
        expect(reviewed.textOf, same(original.textOf));
      }
    },
  );

  for (final factor in [0.85, 2.0]) {
    testWidgets(
      '$factor: outbound weight column survives real resize and action edge tap',
      (tester) async {
        final row = OutboundWeightEntry(
          goodsId: 'outbound-goods',
          qtyOf: () => 10,
          unitRate: 1,
          kg: 12.3456,
        );
        addTearDown(row.dispose);
        var weighs = 0;
        double? minimum;
        Finder header() => tableCellFrame(find.text('实称重量(kg)'));

        await _pump(
          tester,
          factor,
          Builder(
            builder: (context) {
              final column = outboundWeightColumn<OutboundWeightEntry>(
                context: context,
                entryOf: (row) => row,
                entryUnit: WeightUnit.kg,
                onWeighCount: (_, entry) async {
                  expect(entry, same(row));
                  weighs++;
                },
              );
              minimum = column.minimumWidthOf!(context);
              expect(column.exactValueOf!(row), '12.3456');
              return MasterDataTableView<OutboundWeightEntry>(
                items: [row],
                columns: [column],
                facets: const {},
                filters: const {},
                nullCounts: const {},
                onFilterChanged: (_, _) {},
                rowKeyOf: (row) => row.goodsId,
                showColumnChooser: false,
                showFullscreenToggle: false,
              );
            },
          ),
          scaler: factor == 2
              ? const TextScaler.linear(2)
              : TextScaler.noScaling,
        );
        final grip = find.descendant(
          of: header(),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is GestureDetector &&
                widget.onHorizontalDragUpdate != null &&
                widget.onHorizontalDragStart == null &&
                widget.behavior == HitTestBehavior.opaque,
          ),
        );
        await tester.ensureVisible(grip);
        await tester.pumpAndSettle();
        final start = tester.getCenter(grip) - const Offset(2, 0);
        final gripRender = tester.renderObject(grip);
        expect(
          tester
              .hitTestOnBinding(start)
              .path
              .any((entry) => identical(entry.target, gripRender)),
          isTrue,
        );
        await tester.dragFrom(start, const Offset(-500, 0));
        await tester.pumpAndSettle();
        expect(tester.getSize(header()).width, closeTo(minimum!, 1e-6));
        final target = find.byKey(const ValueKey('weight-cell-weigh'));
        final bounds = await _touchTarget(tester, target);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(390));
        final inputRect = tester.getRect(
          find.byKey(const ValueKey('weight-cell-input')),
        );
        expect(bounds.right, lessThanOrEqualTo(inputRect.right + 1e-6));
        expect(
          minimum! - bounds.width / factor - 25,
          greaterThanOrEqualTo(factor == 2 ? 192 : 96),
        );
        await tester.tapAt(Offset(bounds.right - 2, bounds.center.dy));
        await tester.pump();
        expect(weighs, 1);
        expect(row.weight.kg, 12.3456);
        expect(row.qtyBase, 10);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$factor: weighing and add-row edge taps keep their exact row',
      (tester) async {
        final row = _Row();
        final controller = UtenEditableGridController<_Row>(initial: [row]);
        addTearDown(controller.dispose);
        final weighed = <_Row>[];
        final column = weightGridColumn<_Row>(
          controllerOf: (row) => row.weight,
          entryUnit: WeightUnit.kg,
          onWeighCount: (_, row) async => weighed.add(row),
        );
        await _pump(
          tester,
          factor,
          ListView(
            children: [
              UtenEditableGrid<_Row>(
                controller: controller,
                columns: [column],
                createBlankRow: _Row.new,
                showColumnSettings: false,
                showRowDelete: false,
              ),
            ],
          ),
        );
        final weigh = find.byKey(const ValueKey('weight-cell-weigh'));
        final rect = await _touchTarget(tester, weigh);
        final context = tester.element(weigh);
        expect(
          column.chromeWidthOf!(context),
          closeTo(rect.width / factor, 1e-6),
        );
        expect(column.exactValueOf!(row), '12.3456');
        await tester.tapAt(rect.bottomRight - const Offset(2, 2));
        await tester.pump();
        expect(weighed, [same(row)]);
        expect(row.weight.kg, 12.3456);
        final add = find.ancestor(
          of: find.text('添加行'),
          matching: find.byType(FilledButton),
        );
        final addRect = await _touchTarget(tester, add);
        await tester.tapAt(addRect.bottomRight - const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(controller.rows.length, 2);
        expect(controller.rows.first, same(row));
        expect(weighed.length, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$factor: amount-mode edge tap keeps locked quantity and exact input',
      (tester) async {
        final qty = TextEditingController(text: '4');
        final price = TextEditingController(text: '2');
        final pricing = LinePricingController(
          qty: qty,
          price: price,
          canCalculateQuantity: () => false,
        );
        addTearDown(qty.dispose);
        addTearDown(price.dispose);
        addTearDown(pricing.dispose);
        await _pump(tester, factor, LinePricingAmountCell(controller: pricing));
        final mode = find.ancestor(
          of: find.text('算额'),
          matching: find.byType(TextButton),
        );
        final rect = await _touchTarget(tester, mode);
        await tester.tapAt(rect.bottomRight - const Offset(2, 2));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自动算数量'));
        await tester.pump();
        expect(pricing.mode, LinePricingMode.calculateAmount);
        await tester.tap(find.text('自动算单价'));
        await tester.pumpAndSettle();
        expect(pricing.mode, LinePricingMode.calculatePrice);
        await tester.enterText(find.byType(TextField), '20.00');
        await tester.pump();
        expect(pricing.totalAmount.text, '20.00');
        expect(qty.text, '4');
        expect(price.text, '5');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$factor: retry and overflow disclosure have independent touch targets',
      (tester) async {
        final names = _RetryNames();
        final row = FinanceGridRow(mode: ItemMode.allocate)
          ..department.text = 'owner-id';
        addTearDown(row.dispose);
        EditableGridColumn<FinanceGridRow>? department;
        await _pump(
          tester,
          factor,
          SingleChildScrollView(
            child: Builder(
              builder: (context) {
                department = financeGridColumns(
                  ItemMode.allocate,
                  context: context,
                  names: names,
                  type: FinanceDocType.expense,
                  reviewBaseline: const {},
                ).singleWhere((column) => column.key == 'department');
                return Column(
                  children: [
                    department!.cellBuilder(context, row),
                    const SizedBox(
                      width: 140,
                      child: UtenOverflowMessage(
                        message: '这是一条很长的完整错误提示，需要核对后再继续操作。',
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
        final retry = find.byTooltip('加载失败 点击重试');
        final retryRect = await _touchTarget(tester, retry);
        expect(
          department!.chromeWidthOf!(tester.element(retry)),
          closeTo(20 + retryRect.width / factor, 1e-6),
        );
        await tester.tapAt(retryRect.bottomRight - const Offset(2, 2));
        await tester.pump();
        expect(names.retries, 1);
        expect(row.department.text, 'owner-id');
        final disclosure = find.ancestor(
          of: find.byIcon(Icons.help_outline_rounded),
          matching: find.byType(IconButton),
        );
        final helpRect = await _touchTarget(tester, disclosure);
        await tester.tapAt(helpRect.bottomRight - const Offset(2, 2));
        await tester.pump();
        expect(find.text('这是一条很长的完整错误提示，需要核对后再继续操作。'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$factor: tree hit slots and parent-child guide centers agree',
      (tester) async {
        var toggles = 0;
        double? prefix;
        await _pump(
          tester,
          factor,
          Builder(
            builder: (context) {
              prefix = UtenTreeTableCell.prefixWidthOf(
                context,
                depth: 1,
                indent: 24,
              );
              return Column(
                children: [
                  UtenTreeTableCell(
                    key: const ValueKey('parent-tree'),
                    toggleKey: const ValueKey('parent-toggle'),
                    depth: 0,
                    sequence: '',
                    title: '父件',
                    sequenceInline: true,
                    hasChildren: true,
                    expanded: true,
                    indent: 24,
                    onToggle: () => toggles++,
                  ),
                  const UtenTreeTableCell(
                    key: ValueKey('child-tree'),
                    depth: 1,
                    sequence: '',
                    title: '子件',
                    sequenceInline: true,
                    indent: 24,
                  ),
                ],
              );
            },
          ),
        );
        final toggle = find.byKey(const ValueKey('parent-toggle'));
        final rect = await _touchTarget(tester, toggle);
        Finder guide(String key) => find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == '_TreeGuidePainter',
          ),
        );
        final parentGuide = tester.getRect(guide('parent-tree'));
        final childGuide = tester.getRect(guide('child-tree'));
        expect(parentGuide.centerRight.dx, closeTo(rect.center.dx, 1e-6));
        expect(childGuide.left + rect.width / 2, closeTo(rect.center.dx, 1e-6));
        expect(prefix, closeTo(24 + rect.width / factor, 1e-6));
        await tester.tapAt(rect.bottomRight - const Offset(2, 2));
        await tester.pump();
        expect(toggles, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$factor: pending file classification action and remove stay distinct',
      (tester) async {
        const filename = '客户确认合同及生产规格完整版本.pdf';
        final controller = PendingAttachmentController();
        addTearDown(controller.dispose);
        expect(
          controller.add(
            PlatformFile(
              name: filename,
              size: 4,
              bytes: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ),
          isNull,
        );
        final item = controller.items.single;
        var actions = 0;
        await _pump(
          tester,
          factor,
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: PendingAttachmentSection(
                controller: controller,
                canManage: true,
                categories: const ['客户确认', '合同'],
                actionFor: (_) => PendingFileActionSpec(
                  label: 'AI识别',
                  onTap: () => actions++,
                ),
              ),
            ),
          ),
          scaler: factor == 2
              ? const TextScaler.linear(2)
              : TextScaler.noScaling,
        );
        final name = tester.widget<Text>(find.text(filename));
        expect(name.maxLines, isNull);
        expect(name.overflow, isNull);
        final category = find.descendant(
          of: find.byType(AttachmentCategoryControl),
          matching: find.byType(InkWell),
        );
        final categoryRect = await _touchTarget(tester, category);
        await tester.tapAt(categoryRect.bottomRight - const Offset(2, 2));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is CheckedPopupMenuItem<String> &&
                widget.value == '客户确认',
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.items.single, same(item));
        expect(item.category, '客户确认');
        expect(actions, 0);
        final action = find.descendant(
          of: find.byKey(const ValueKey('pending-attachment-action-$filename')),
          matching: find.byType(InkWell),
        );
        final actionRect = await _touchTarget(tester, action);
        await tester.tapAt(Offset(actionRect.right - 2, actionRect.center.dy));
        await tester.pump();
        expect(actions, 1);
        expect(controller.items.single, same(item));
        expect(item.bytes, [1, 2, 3, 4]);
        final remove = find.byKey(
          const ValueKey('pending-attachment-remove-$filename'),
        );
        final removeRect = await _touchTarget(tester, remove);
        await tester.tapAt(removeRect.bottomRight - const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(controller.items, isEmpty);
        expect(actions, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'responsive chrome survives reviewed cloning and size preference changes',
    (tester) async {
      final row = _Row();
      final controller = UtenEditableGridController<_Row>(initial: [row]);
      final factor = ValueNotifier(1.0);
      addTearDown(controller.dispose);
      addTearDown(factor.dispose);
      double? cellWidth;
      final original = EditableGridColumn<_Row>(
        key: 'amount',
        label: '重量',
        width: 80,
        textOf: (row) => row.text.text,
        listenableOf: (row) => row.text,
        chromeWidthOf: (context) =>
            UtenControlMetrics.minimumHitExtent(context, desktop: 32),
        cellBuilder: (_, row) => LayoutBuilder(
          builder: (_, constraints) {
            cellWidth = constraints.maxWidth;
            return TextField(controller: row.text);
          },
        ),
      );
      final columns = reviewedGridColumns<_Row>(
        columns: [original],
        baseline: const {},
        valuesOf: (_) => const {},
        listenableOf: (row) => row.text,
        editableKeys: const {'amount'},
        keyPrefix: 'touch-review',
      );
      expect(columns.single.chromeWidthOf, same(original.chromeWidthOf));
      await _pump(
        tester,
        1,
        ValueListenableBuilder<double>(
          valueListenable: factor,
          builder: (_, value, child) =>
              UtenDisplayZoomBox(fontFactor: value, child: child!),
          child: ListView(
            children: [
              UtenEditableGrid<_Row>(
                controller: controller,
                columns: columns,
                showAddRow: false,
                showColumnSettings: false,
                showRowDelete: false,
              ),
            ],
          ),
        ),
      );
      final before = cellWidth!;
      factor.value = 0.85;
      await tester.pumpAndSettle();
      expect(cellWidth! - before, closeTo(48 / .85 - 48, 1e-6));
      expect(row.text.text, '实称重量12345');
      await tester.enterText(find.byType(TextField), '实称重量123451234512345');
      await tester.pump();
      expect(cellWidth, greaterThan(before + 48 / .85 - 48));
      expect(row.text.text, '实称重量123451234512345');
      expect(tester.takeException(), isNull);
    },
  );
}
