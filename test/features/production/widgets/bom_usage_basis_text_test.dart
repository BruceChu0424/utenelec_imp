import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/widgets/bom_usage_basis_text.dart';

void main() {
  final l10n = AppLocalizationsZh();

  test('真实使用数量：说明依据几批与设计值', () {
    expect(
      formatBomUsageBasis(
        l10n,
        usesActual: true,
        usedQty: 0.105,
        designQty: 0.1,
        actualQty: 0.105,
        sampleCount: 12,
      ),
      '每件按真实使用数量 0.105 计算(12 批累计，设计 0.1)',
    );
    expect(
      formatBomUsageBasis(l10n, usesActual: true, usedQty: 2),
      '每件按真实使用数量 2 计算',
    );
  });

  test('真实使用数量附带不良率：大于 0 才列出，按设计时不出现', () {
    expect(
      formatBomUsageBasis(
        l10n,
        usesActual: true,
        usedQty: 0.105,
        designQty: 0.1,
        sampleCount: 12,
        defectRate: 0.0325,
      ),
      '每件按真实使用数量 0.105 计算(12 批累计，设计 0.1，不良率 3.25%)',
    );
    expect(
      formatBomUsageBasis(l10n, usesActual: true, usedQty: 2, defectRate: 0.1),
      '每件按真实使用数量 2 计算(不良率 10%)',
    );
    for (final rate in [0.0, null]) {
      expect(
        formatBomUsageBasis(
          l10n,
          usesActual: true,
          usedQty: 2,
          designQty: 2,
          defectRate: rate,
        ),
        '每件按真实使用数量 2 计算(设计 2)',
      );
    }
    expect(
      formatBomUsageBasis(
        l10n,
        usesActual: false,
        usedQty: 0.1,
        reason: 'NO_DATA',
        defectRate: 0.2,
      ),
      isNot(contains('不良率')),
    );
  });

  test('设计使用数量：原因与组装信息页同一份人话(多语言)，不露代码', () {
    final texts = {
      for (final reason in const [
        'NO_DATA',
        'NOT_LINEAR',
        'OUTPUT_UNIT_CHANGED',
        'SUBCONTRACT_OUTBOUND',
        null,
        'SOMETHING_NEW',
      ])
        reason: formatBomUsageBasis(
          l10n,
          usesActual: false,
          usedQty: 0.1,
          reason: reason,
        ),
    };
    for (final entry in texts.entries) {
      expect(
        entry.value,
        '每件按设计使用数量 0.1 计算：${bomDesignReasonText(l10n, entry.key)}',
      );
    }
    expect(texts['OUTPUT_UNIT_CHANGED'], contains('需重新学习'));
    expect(
      texts['SUBCONTRACT_OUTBOUND'],
      '每件按设计使用数量 0.1 计算：上级委外件按领料把这个物料发给委外商，按委外合同(设计)用量',
    );
    for (final text in texts.values) {
      expect(text, isNot(matches(RegExp('[A-Z_]{4,}'))));
      expect(text, isNot(contains('（')));
    }
    // 委外合同用量下仍给出本厂真实使用数量作参考。
    expect(
      formatBomUsageBasis(
        l10n,
        usesActual: false,
        usedQty: 0.1,
        actualQty: 0.105,
        reason: 'SUBCONTRACT_OUTBOUND',
      ),
      '每件按设计使用数量 0.1 计算：上级委外件按领料把这个物料发给委外商，按委外合同(设计)用量(真实使用数量 0.105)',
    );
  });

  test('用量口径跟随计量方式：每 N 件 / 每批', () {
    expect(bomUsagePerLabel('PER_UNIT', 1), '每件');
    expect(bomUsagePerLabel('PER_PACKAGE', 12), '每 12 件');
    expect(bomUsagePerLabel('PER_PACKAGE', 1), '每件');
    expect(bomUsagePerLabel('FIXED_BATCH', 50), '每批');
    expect(bomUsagePerLabel(null, null), '每件');
  });

  test('物料分析节点：只给有 BOM 边的行说明', () {
    const node = ProductionMaterialAnalysisMaterial(
      materialLineId: 'm',
      actionable: true,
      bomQty: 3,
      designBomQty: 2.5,
      actualBomQty: 3,
      usageBasis: 'ACTUAL',
      usageSampleCount: 4,
      consumptionBasis: 'PER_PACKAGE',
      basisOutputQty: 10,
    );
    expect(
      materialAnalysisUsageBasisText(l10n, node),
      '每 10 件按真实使用数量 3 计算(4 批累计，设计 2.5)',
    );
    expect(
      materialAnalysisUsageBasisText(
        l10n,
        const ProductionMaterialAnalysisMaterial(
          materialLineId: 'root',
          actionable: true,
          nodeRole: 'ROOT_SUPPLY',
          bomQty: 1,
        ),
      ),
      isNull,
    );
    expect(
      materialAnalysisUsageBasisText(
        l10n,
        const ProductionMaterialAnalysisMaterial(
          materialLineId: 'no-edge',
          actionable: true,
        ),
      ),
      isNull,
    );
    final parsed = ProductionMaterialAnalysisMaterial.fromJson({
      'materialLineId': 'legacy',
      'bomQty': 0.2,
      'designBomQty': 0.2,
      'usageReason': 'NO_DATA',
    });
    expect(parsed.usageBasis, 'DESIGN');
    expect(parsed.usageDefectRate, isNull);
    expect(
      materialAnalysisUsageBasisText(l10n, parsed),
      '每件按设计使用数量 0.2 计算：${l10n.bomDesignReasonNoData}',
    );
  });

  test('物料分析节点：采用真实使用数量时带上一起锁定的不良率', () {
    final actual = ProductionMaterialAnalysisMaterial.fromJson({
      'materialLineId': 'actual',
      'bomQty': 0.105,
      'designBomQty': 0.1,
      'actualBomQty': 0.105,
      'usageBasis': 'ACTUAL',
      'usageSampleCount': 12,
      'usageDefectRate': 0.0325,
    });
    expect(actual.usageDefectRate, 0.0325);
    expect(
      materialAnalysisUsageBasisText(l10n, actual),
      '每件按真实使用数量 0.105 计算(12 批累计，设计 0.1，不良率 3.25%)',
    );
    final noDefect = ProductionMaterialAnalysisMaterial.fromJson({
      'materialLineId': 'no-defect',
      'bomQty': 0.105,
      'designBomQty': 0.1,
      'usageBasis': 'ACTUAL',
      'usageSampleCount': 12,
      'usageDefectRate': 0,
    });
    expect(
      materialAnalysisUsageBasisText(l10n, noDefect),
      '每件按真实使用数量 0.105 计算(12 批累计，设计 0.1)',
    );
  });
}
