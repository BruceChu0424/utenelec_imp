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
    'plan creation leaves the number to the server after wizard retirement',
    () {
      final editPage = File(
        'lib/features/production/pages/production_plan_edit_page.dart',
      ).readAsStringSync();
      // 物料分析页已拆 part 模块（5ad31944）：契约匹配主页与全部 part 的拼接源。
      final analysisLibrary = [
        'lib/features/production/pages/production_material_analysis_page.dart',
        ...Directory('lib/features/production/pages/')
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where(
              (p) => p.endsWith('.dart') && p.contains('material_analysis_'),
            ),
      ].map((p) => File(p).readAsStringSync()).join('\n');

      expect(editPage, contains('initialProductNo: row.productNo.text.trim()'));
      // 2026-09-04 起「填写生产计划单」向导页下线（可安排桶直接生成+下发），
      // 分析侧不再手工指定产品编号——统一留空由服务端按计划单号生成；
      // 分析链路不得再引用向导专属的产品编号 seed。
      expect(analysisLibrary, isNot(contains('initialProductNoFor(')));
      expect(analysisLibrary, isNot(contains('ProductionPlanWizard')));
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
