// 仓库专属重量口径契约 (ADR-135, 2026-09-28 用户拍板, 取代 2026-08-30 审计的 NO-GO 清单):
//
// 1. 数量 (数量 + 单位 + 换算率) 仍是计划/采购/销售/生产/财务唯一的事实; 这些业务单据
//    编辑页不加重量录入, 历史隐藏重量字段原样透传不清零。
// 2. 仓库每条录入/确认数量的执行行都有「实称重量」列 (共用 weightGridColumn), 放在数量组之后;
//    重量以千克 4 位提交, 连同「按称重改数量」计入幂等键; 货品/行单位按重量计时只读、不提交
//    (服务端按数量精确换算), 单据上绝不写估算重量。
// 3. 销售侧「实际重量」输入照旧 (不再进库存账, 由仓库出库实称代替)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('business documents keep quantity as the only planning fact', () {
    final purchaseGrid = source(
      'lib/features/purchase/widgets/purchase_grid_columns.dart',
    );
    final purchaseEdit = source(
      'lib/features/purchase/pages/purchase_doc_edit_page.dart',
    );
    final salesGrid = source(
      'lib/features/sales/widgets/sales_grid_columns.dart',
    );
    final salesEdit = source(
      'lib/features/sales/pages/sales_doc_edit_page.dart',
    );
    final dailyGrid = source(
      'lib/features/production/widgets/production_daily_grid_columns.dart',
    );
    final dailyEdit = source(
      'lib/features/production/pages/production_daily_report_edit_page.dart',
    );

    // 采购/销售/生产日报编辑网格没有重量列 (单位已表达数量含义, 重量是仓库的事)。
    for (final grid in [purchaseGrid, salesGrid, dailyGrid]) {
      expect(grid, isNot(contains("key: 'weight'")));
      expect(grid, isNot(contains("label: '实际重量'")));
      expect(grid, isNot(contains('weightGridColumn')));
    }
    // 历史重量仍回填、复制、校验并随原单提交, 不能被静默清零。
    expect(dailyGrid, contains('c.weight.text = weight.text;'));
    expect(
      dailyEdit,
      contains("row.weight.text = group.weight?.toString() ?? '';"),
    );
    expect(dailyEdit, contains("'weight': ?weight"));
    for (final edit in [purchaseEdit, salesEdit, dailyEdit]) {
      expect(edit, contains("'weight'"));
      expect(edit, contains('实际重量必须大于 0'));
    }
  });

  test(
    'warehouse capture grids share the weight cell after the quantity group',
    () {
      final inbound = source(
        'lib/features/warehouse/widgets/inbound_registration_widgets.dart',
      );
      final stockGrid = source(
        'lib/features/warehouse/widgets/stock_grid_columns.dart',
      );
      final arrival = source(
        'lib/features/warehouse/pages/warehouse_arrival_receipt_page.dart',
      );
      final arrivalBatch = source(
        'lib/features/warehouse/pages/warehouse_arrival_batch_receipt_page.dart',
      );

      // 入库登记与仓库单据都用共用的实称重量格 (后缀换算、永不批量、按重量计只读)。
      expect(inbound, contains('weightGridColumn<T>('));
      expect(stockGrid, contains('weightGridColumn<StockGridRow>('));
      // 盘点: 实盘后是只读账面重量与可选实盘重量。
      expect(stockGrid, contains("key: 'bookWeight'"));
      expect(stockGrid, contains("key: 'countWeight'"));
      // 列序: 单位 → 实称重量 (数量组之后, 不把数量与单位拆开)。
      for (final page in [arrival, arrivalBatch]) {
        final unit = page.indexOf('shared.unit(),');
        final weight = page.indexOf('shared.weight(');
        final warehouse = page.indexOf('shared.warehouse(');
        expect(unit, greaterThan(0));
        expect(weight, greaterThan(unit));
        expect(warehouse, greaterThan(weight));
      }
    },
  );

  test('warehouse requests send measured kg only and key it for idempotency', () {
    final arrival = source(
      'lib/features/warehouse/pages/warehouse_arrival_receipt_page.dart',
    );
    final arrivalBatch = source(
      'lib/features/warehouse/pages/warehouse_arrival_batch_receipt_page.dart',
    );
    final finished = source(
      'lib/features/warehouse/pages/production_finished_arrival_registration_page.dart',
    );
    final finishedBatch = source(
      'lib/features/warehouse/pages/production_finished_arrival_batch_registration_page.dart',
    );
    final stockEdit = source(
      'lib/features/warehouse/pages/stock_doc_edit_page.dart',
    );

    for (final page in [arrival, arrivalBatch]) {
      expect(page, contains("'weight': ?_sentKg(line),"));
      expect(page, contains("'qtyFromWeight': true"));
      // 内容派生的幂等键带上行重量片段。
      expect(page, contains(r"'${_weightKeyPart(line)}'"));
      // 精确换算行不带重量 (服务端按数量算 EXACT)。
      expect(page, contains('_exactKg(line) == null ? line.weight.kg : null'));
    }
    for (final page in [finished, finishedBatch]) {
      expect(page, contains("'weight': ?_sentKg(row),"));
      expect(page, contains('warehouseWeightKeySuffix('));
      // 产成品登记只核对不回填数量 (没有称重计数按钮)。
      expect(page, isNot(contains('onWeighCount')));
    }
    expect(stockEdit, contains("m['weight'] = sentKg"));
    expect(stockEdit, contains("m['countWeight'] = sentKg"));
    expect(stockEdit, contains("m['qtyFromWeight'] = true"));
    // 单据上绝不写估算: 只提交格子里的实称值, 没有单重乘数量的回写。
    for (final page in [
      arrival,
      arrivalBatch,
      finished,
      finishedBatch,
      stockEdit,
    ]) {
      expect(page, isNot(contains('expectedKgFor(')));
    }
  });

  test('business quantity keeps unit rate and never derives parcel count', () {
    final picker = source(
      'lib/components/layout/uten_doc_link_picker_sheet.dart',
    );
    final purchaseEdit = source(
      'lib/features/purchase/pages/purchase_doc_edit_page.dart',
    );
    final salesEdit = source(
      'lib/features/sales/pages/sales_doc_edit_page.dart',
    );

    expect(picker, contains('unitRate: _cfg.itemFields.unitRate?.call(it)'));
    expect(purchaseEdit, contains("'unitRate': r.unitRate"));
    expect(salesEdit, contains("'unitRate': r.unitRate"));
    expect(salesEdit, isNot(contains('_computedParcelCount')));
    expect(salesEdit, contains("labelText: '物流件数'"));
    // 底部合计条统一走 UtenTotalsSummaryBar，数量项由 utenQuantityTotalEntry 构造
    // (按单位分组、绝不跨单位相加)。两种写法都满足本契约。
    expect(
      salesEdit.contains('measurementTotalsText(') ||
          salesEdit.contains('utenQuantityTotalEntry('),
      isTrue,
      reason: '销售编辑页数量合计必须按单位分组，不得跨单位相加',
    );
  });

  test('sales-side batch shipment weight stays as is', () {
    final batch = source(
      'lib/features/sales/widgets/sales_batch_ship_panel.dart',
    );
    // 销售侧实际重量输入原样保留 (ADR-135 §3.7: 不再进库存账)。
    expect(batch, contains("'weight': ?weight"));
  });
}
