import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

void main() {
  test('sales-order import leaves product number authority to the server', () {
    final source = File(
      'lib/features/production/pages/production_plan_edit_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains(r"..productNo.text = '${d.billNo")));
    expect(source, isNot(contains('行缺少产品编号')));
    expect(source, contains('if (r.productNo.text.trim().isNotEmpty)'));
  });

  test(
    'product number editor is optional and explains automatic allocation',
    () {
      final source = File(
        'lib/features/production/widgets/production_grid_columns.dart',
      ).readAsStringSync();
      final start = source.indexOf("key: 'productNo'");
      final end = source.indexOf("key: 'goods'", start);

      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final productColumn = source.substring(start, end);
      expect(productColumn, isNot(contains('required: true')));
      expect(productColumn, isNot(contains('RequiredCellFrame')));
      expect(productColumn, contains("hintText: '留空由系统生成'"));
    },
  );

  test(
    'plan creation carries the optional number through analysis and wizard',
    () {
      final editPage = File(
        'lib/features/production/pages/production_plan_edit_page.dart',
      ).readAsStringSync();
      final analysisPage = File(
        'lib/features/production/pages/production_material_analysis_page.dart',
      ).readAsStringSync();
      final wizardPage = File(
        'lib/features/production/pages/production_plan_wizard_page.dart',
      ).readAsStringSync();

      expect(editPage, contains('initialProductNo: row.productNo.text.trim()'));
      expect(analysisPage, contains('widget.seed.initialProductNoFor('));
      expect(wizardPage, contains("labelText: '产品编号（可选）'"));
      expect(wizardPage, contains("helperText: '留空由系统按计划单号生成'"));
      expect(
        wizardPage,
        contains('productNo: productNoController.text.trim()'),
      );
    },
  );

  test('route-local product number seed uses stable source identity only', () {
    const sales = MaterialAnalysisSourceInput(
      salesOrderItemId: 'sales-line-1',
      requestedQty: 5,
      initialProductNo: '  V6-0001  ',
    );
    const manual = MaterialAnalysisSourceInput(
      sourceType: 'SAMPLE',
      sourceRef: 'sample-20260814-1',
      goodsId: 'goods-1',
      colorId: 'color-1',
      unitId: 'unit-1',
      requestedQty: 2,
      initialProductNo: 'SAMPLE-001',
    );
    const seed = ProductionMaterialAnalysisSeed(sources: [sales, manual]);

    expect(sales.toJson(), isNot(contains('initialProductNo')));
    expect(sales.toJson(), isNot(contains('productNo')));
    expect(
      seed.initialProductNoFor(
        const ProductionMaterialAnalysisProduct(
          analysisLineId: 'analysis-line-1',
          salesOrderItemId: 'sales-line-1',
        ),
      ),
      'V6-0001',
    );
    expect(
      seed.initialProductNoFor(
        const ProductionMaterialAnalysisProduct(
          analysisLineId: 'analysis-line-2',
          sourceType: 'sample',
          sourceRef: 'SAMPLE-20260814-1',
          goodsId: 'goods-1',
          colorId: 'color-1',
          unitId: 'unit-1',
        ),
      ),
      'SAMPLE-001',
    );
    expect(
      seed.initialProductNoFor(
        const ProductionMaterialAnalysisProduct(
          analysisLineId: 'analysis-line-3',
          salesOrderItemId: 'sales-line-other',
        ),
      ),
      isNull,
    );
  });
}
