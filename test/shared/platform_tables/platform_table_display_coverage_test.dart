import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/production/models/workshop_material_report_models.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/quality/models/production_fqc_inspection.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'package:uten_imp/features/warehouse/models/outbound_weight_entry.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_document_history.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_insight.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/widgets/outbound_weight_columns.dart';
import 'package:uten_imp/features/warehouse/widgets/production_draw_detail_table.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_insight_tables.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_outbound_table_columns.dart';
import 'package:uten_imp/platform_table_registry.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_widgets.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/stock_ledger/stock_ledger_models.dart';

PlatformTableBinding<T> _binding<T>(T row, String key) => resolvePlatformTable(
  PlatformTableDescriptor<T>(
    kind: 'master',
    tableKey: key,
    columnKeys: const [],
    rows: [row],
  ),
)!;

void _expectDisplayOnly<T>(
  T row,
  String tableKey,
  Map<String, String?> expected,
) {
  final binding = _binding(row, tableKey);
  expect(
    binding.recordIdOf(row),
    isNull,
    reason: 'A display row is not a writable business identity',
  );
  expect(binding.canEditValues, isFalse);
  final facts = binding.factValuesOf!(row);
  for (final entry in expected.entries) {
    expect(
      facts[entry.key],
      entry.value,
      reason: '${row.runtimeType}.${entry.key}',
    );
  }
}

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '原料';
  @override
  String warehouse(String? id) => '原料仓';
}

void main() {
  test(
    'external insight columns retain missing weights, raw ages and masked exact costs',
    () {
      final columns = insightHealthColumns(
        display: WeightDisplay.auto,
        showAmount: true,
      );
      final row = InsightHealthRow.fromJson({
        'goodsId': 'goods',
        'qty': 1.23456789,
        'age0_30': 0.00012345,
        'amountLocal': 9007199254740992,
        'amountLocalExact': '9007199254740993.00000001',
        'costMasked': false,
      });
      String? value(String key, InsightHealthRow row) =>
          columns.singleWhere((column) => column.key == key).exactValueOf!(row);
      expect(value('qty', row), '1.23456789');
      expect(value('age0_30', row), '0.00012345');
      expect(value('weightKg', row), isNull);
      expect(value('amountLocal', row), '9007199254740993.00000001');
      const masked = InsightHealthRow(
        goodsId: 'hidden',
        amountLocalText: '12345',
      );
      expect(value('amountLocal', masked), isNull);
    },
  );

  test(
    'sampling helper exposes live raw quantity and kilograms with no draft persistence',
    () {
      final draft = InsightSampleDraft();
      addTearDown(draft.dispose);
      const row = InsightLearningRow(goodsId: 'sample');
      final columns = insightLearningColumns(
        sampleUnit: WeightUnit.g,
        draftOf: (_) => draft,
        canSample: true,
        onSave: (_) {},
      );
      final qty = columns.singleWhere((column) => column.key == 'sampleQty');
      final weight = columns.singleWhere(
        (column) => column.key == 'sampleWeight',
      );
      var updates = 0;
      weight.exactListenableOf!(row)!.addListener(() => updates++);
      draft.qty.text = '12.125';
      draft.weight.text = '850g';
      expect(qty.exactValueOf!(row), '12.125');
      expect(businessExactDecimal(weight.exactValueOf!(row)), '0.85');
      expect(updates, 1);
      draft.weight.text = 'unknown';
      expect(weight.exactValueOf!(row), isNull);
      expect(draft.saved, isFalse);
    },
  );

  test(
    'external shipment helper uses decimal source values and excludes line identities',
    () {
      const line = WarehouseSalesOutboundLine(
        id: 'line',
        lineNumber: 123,
        quantity: '9007199254740993.00000001',
        parcelQuantity: '12.25',
        cartonCount: 3,
        weightKg: 0.85,
      );
      const detail = WarehouseSalesOutboundDetail(
        header: WarehouseSalesOutboundSummary(
          id: 'shipment',
          allowedWarehouseTargets: {},
        ),
        lines: [line],
      );
      const row = WarehouseSalesOutboundTableRow(detail, line);
      final columns = warehouseSalesOutboundTableColumns(
        l10n: AppLocalizationsZh(),
        rows: [row],
      );
      expect(
        columns.singleWhere((column) => column.key == 'quantity').exactValueOf!(
          row,
        ),
        '9007199254740993.00000001',
      );
      expect(
        columns
            .singleWhere((column) => column.key == 'parcelQuantity')
            .exactValueOf!(row),
        '12.25',
      );
      expect(
        columns.singleWhere((column) => column.key == 'weight').exactValueOf!(
          row,
        ),
        '0.85',
      );
      expect(
        columns
            .singleWhere((column) => column.key == 'lineNumber')
            .exactValueOf,
        isNull,
      );
    },
  );

  test(
    'IQC rejection amounts remain masked even if the model contains a value',
    () {
      const row = ProcurementIqcRejectionCase(
        id: 'case',
        receiptType: ProcurementIqcReceiptType.purchase,
        status: ProcurementIqcRejectionStatus.pendingReturn,
        version: 1,
        allowedActions: {},
        priceMasked: true,
        failedQty: '1.25',
        failedAmountLocal: '9007199254740993.00000001',
      );
      final binding = _binding(row, 'procurement_iqc_rejection.list');
      expect(binding.scope, 'view_procurement_iqc_rejection');
      expect(binding.factValuesOf!(row)['failedQty'], '1.25');
      expect(binding.factValuesOf!(row)['amount'], isNull);
      expect(binding.recordIdOf(row), isNull);
    },
  );

  test(
    'planning values preserve unrounded decimals and missing analysis remains missing',
    () {
      const row = SchedulePendingRow(
        orderItemId: 'line',
        orderId: 'order',
        qty: 12.123456789,
        needQty: 10,
        plannedQty: 2.1,
      );
      _expectDisplayOnly(row, 'production.pending', {
        'qty': '12.123456789',
        'needQty': '10.0',
        'plannedQty': '2.1',
        'analysisCoveredQty': null,
      });
    },
  );

  test(
    'FQC separates reported, passed, failed, remaining and released quantities',
    () {
      final row = ProductionFqcInspection(
        id: 'inspection',
        sourceReportId: 'report',
        sourceReportItemId: 'report-line',
        reportedQty: 12.25,
        passedQty: 6.5,
        failedQty: 1.25,
        remainingQty: 4.5,
        authorizedInboundQty: 3.25,
        status: 'PARTIAL',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      _expectDisplayOnly(row, 'quality.fqc', {
        'reportedQty': '12.25',
        'passedQty': '6.5',
        'failedQty': '1.25',
        'remainingQty': '4.5',
        'authorizedInboundQty': '3.25',
      });
    },
  );

  test(
    'physical history preserves decimal text and does not promote absent quantity to zero',
    () {
      const row = WarehouseDocumentPhysicalItem(
        id: 'historical-line',
        qty: '9007199254740993.00000001',
        returnedQty: '0.00000001',
        passedBaseQty: '4.5',
      );
      _expectDisplayOnly(row, 'warehouse.history', {
        'quantity': '9007199254740993.00000001',
        'returnedQuantity': '0.00000001',
        'iqcPassedBaseQuantity': '4.5',
        'boxQuantity': null,
      });
    },
  );

  for (final input in [
    {'taskId': 'group', 'goodsCount': 2, 'requiredQty': 9, 'openQty': 5},
    {
      'taskId': 'discovery',
      'taskStatus': 'MATERIALS_TO_DEFINE',
      'requiredQty': 9,
      'openQty': 5,
    },
  ]) {
    test(
      'mixed or undiscovered quantities cannot become formula inputs: ${input['taskId']}',
      () {
        final row = OperationsWorkbenchTask.fromJson({
          'supplyRoute': 'PURCHASE',
          'taskStatus': 'PENDING',
          ...input,
        }, OperationsWorkbenchDepartment.purchase);
        _expectDisplayOnly(row, 'operations.tasks', {
          'requiredQty': null,
          'allocatedQty': null,
          'fulfilledQty': null,
          'openQty': null,
        });
      },
    );
  }

  test(
    'shared consumption uses allocation basis and suppresses nonexclusive per-unit actuals',
    () {
      const row = WmBinUsageRow(
        costBasis: 'SHARED',
        allocationBasisQty: 13.25,
        theoryQty: 99,
        wasteRate: 0.125,
      );
      _expectDisplayOnly(row, 'production.material.usage', {'theory': '13.25'});
      expect(
        businessExactDecimal(platformDisplayFacts(row)['wasteRate']),
        '12.5',
      );
      final mixed = WmProductUsageRow.fromJson({
        'actualPerUnitGrams': 88,
        'exclusivePeriod': false,
      });
      _expectDisplayOnly(mixed, 'production.material.usage', {
        'actualPerUnit': null,
      });
    },
  );

  test(
    'stock corrections do not masquerade as physical receipts or shipments',
    () {
      const out = StockLedgerRow(
        rowKind: 'M',
        id: 'out',
        qtySigned: -1.25,
        balanceQtyAfter: 2.5,
      );
      const weightOnly = StockLedgerRow(
        rowKind: 'W',
        id: 'correction',
        qtySigned: 999,
        weightKgSigned: 0.2,
        balanceQtyAfter: 2.5,
      );
      _expectDisplayOnly(out, 'warehouse.ledger', {
        'inQty': null,
        'outQty': '1.25',
        'balanceQty': '2.5',
      });
      _expectDisplayOnly(weightOnly, 'warehouse.ledger', {
        'inQty': null,
        'outQty': null,
        'balanceQty': '2.5',
      });
    },
  );

  test(
    'asset reference formulas retain exact money and inherit price denial',
    () {
      const row = FinanceAssetScheduleLine(
        period: '2026-09',
        openingBalance: '9007199254740993.00000001',
        amount: '0.00000001',
        accumulatedAmount: '1',
        closingBalance: '9007199254740993',
        status: 'POSTED',
      );
      final binding = _binding(row, 'finance.asset.schedule');
      expect(binding.scope, 'view_finance_asset');
      expect(binding.recordIdOf(row), isNull);
      final controller = PlatformTableController<FinanceAssetScheduleLine>()
        ..binding = binding;
      addTearDown(controller.dispose);
      PlatformTableCapabilities capabilities(bool priceVisible) =>
          PlatformTableCapabilities(
            scope: binding.scope,
            supportsValues: false,
            priceVisible: priceVisible,
            facts: const [
              PlatformTableFact(
                key: 'openingBalance',
                name: '期初',
                priceProtected: true,
              ),
              PlatformTableFact(
                key: 'amount',
                name: '本期',
                priceProtected: true,
              ),
            ],
          );
      const formula = PlatformColumnDefinition(
        id: 'remaining',
        scope: 'view_finance_asset',
        name: '参考余额',
        type: 'CALCULATED',
        formula: PlatformFormula(
          base: PlatformFormulaOperand(fact: 'openingBalance'),
          steps: [
            PlatformFormulaStep(
              operation: 'SUBTRACT',
              operand: PlatformFormulaOperand(fact: 'amount'),
            ),
          ],
        ),
      );
      controller.capabilities = capabilities(true);
      expect(
        businessExactDecimal(controller.value(row, formula)),
        '9007199254740993',
      );
      controller.capabilities = capabilities(false);
      expect(controller.value(row, formula), isNull);
      expect(row.closingBalance, '9007199254740993');
    },
  );

  testWidgets(
    'merged draw quantities use decimal operands rather than rounded display or binary sums',
    (tester) async {
      StockDocDetail document(String id, double quantity) => StockDocDetail(
        id: id,
        docType: 'DRAW',
        status: 1,
        drawBatchNo: 'batch',
        items: [
          StockDocItem(
            id: '$id-line',
            goodsId: 'goods',
            unitId: 'kg',
            qty: quantity,
            issuedQty: 0,
          ),
        ],
      );
      final documents = [document('a', 0.1), document('b', 0.2)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProductionDrawDetailTable(
              documents: documents,
              names: _Names(),
              permissions: const {},
              mergeBatchGoods: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<ProductionDrawDetailRow>>(
        find.byType(MasterDataTableView<ProductionDrawDetailRow>),
      );
      final row = table.items.single;
      expect(row.isMergedGroup, isTrue);
      final qty = table.columns.singleWhere((column) => column.key == 'qty');
      expect(qty.exactValueOf!(row), '0.3');
      final remaining = table.columns.singleWhere(
        (column) => column.key == 'remainingQty',
      );
      expect(remaining.exactValueOf!(row), '0.3');
      expect(documents.map((doc) => doc.items.single.qty), [0.1, 0.2]);
    },
  );

  testWidgets(
    'weight formulas react to suffix input and keep kilograms when display unit changes',
    (tester) async {
      final row = OutboundWeightEntry(goodsId: 'goods', qtyOf: () => 10);
      addTearDown(row.dispose);
      final column = outboundWeightColumn<OutboundWeightEntry>(
        entryOf: (value) => value,
        entryUnit: WeightUnit.kg,
      );
      final controller = PlatformTableController<OutboundWeightEntry>()
        ..fallbackFactsOf = ((value) => {'weight': column.exactValueOf!(value)})
        ..fallbackFactListenablesOf = (value) => [
          column.exactListenableOf!(value)!,
        ];
      addTearDown(controller.dispose);
      const calculation = PlatformColumnDefinition(
        id: 'double-weight',
        scope: '',
        name: '两倍实称重量',
        type: 'CALCULATED',
        formula: PlatformFormula(
          base: PlatformFormulaOperand(fact: 'weight'),
          steps: [
            PlatformFormulaStep(
              operation: 'MULTIPLY',
              operand: PlatformFormulaOperand(constant: '2'),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlatformColumnValue(
              controller: controller,
              row: row,
              column: calculation,
            ),
          ),
        ),
      );
      row.weight.text.text = '850g';
      await tester.pump();
      expect(column.exactValueOf!(row), '0.85');
      expect(businessExactDecimal(controller.value(row, calculation)), '1.7');
      final renderedResult = find.byWidgetPredicate(
        (widget) =>
            widget is Text && businessExactDecimal(widget.data) == '1.7',
      );
      expect(renderedResult, findsOneWidget);
      row.weight.switchUnit(WeightUnit.g);
      await tester.pump();
      expect(row.weight.text.text, '850');
      expect(column.exactValueOf!(row), '0.85');
      expect(renderedResult, findsOneWidget);
      row.weight.text.clear();
      await tester.pump();
      expect(find.text('计算不可用'), findsOneWidget);
    },
  );
}
