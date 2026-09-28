import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';

void main() {
  test('legacy BOM responses keep the historical control defaults', () {
    final item = GoodsBomItem.fromJson({
      'id': 'row-1',
      'componentGoodsId': 'component-1',
    });

    expect(item.controlStage, BomControlStage.start);
    expect(item.consumptionBasis, BomConsumptionBasis.perUnit);
    expect(item.basisOutputQty, 1);
    expect(item.allowPartialPackage, isTrue);
    expect(item.hardGate, isTrue);
  });

  test('BOM responses parse packaging controls and friendly labels', () {
    final item = GoodsBomItem.fromJson({
      'id': 'row-2',
      'componentGoodsId': 'component-2',
      'controlStage': 'FINISH',
      'consumptionBasis': 'PER_PACKAGE',
      'basisOutputQty': 100,
      'allowPartialPackage': false,
      'hardGate': false,
    });

    expect(item.controlStage, BomControlStage.finish);
    expect(item.controlStage.label, '完工/包装前');
    expect(item.consumptionBasis, BomConsumptionBasis.perPackage);
    expect(item.consumptionBasis.label, '按包装');
    expect(item.basisOutputQty, 100);
    expect(item.allowPartialPackage, isFalse);
    expect(item.hardGate, isFalse);
  });

  test(
    'shipping and reference stages are always warning-only in the model',
    () {
      final shipping = GoodsBomItem.fromJson({
        'id': 'row-ship',
        'componentGoodsId': 'component-ship',
        'controlStage': 'SHIP',
        'hardGate': true,
      });
      final reference = GoodsBomItem.fromJson({
        'id': 'row-reference',
        'componentGoodsId': 'component-reference',
        'controlStage': 'REFERENCE',
        'hardGate': true,
      });

      expect(BomControlStage.start.supportsHardGate, isTrue);
      expect(BomControlStage.assembly.supportsHardGate, isTrue);
      expect(BomControlStage.finish.supportsHardGate, isTrue);
      expect(BomControlStage.ship.supportsHardGate, isFalse);
      expect(BomControlStage.reference.supportsHardGate, isFalse);
      expect(shipping.hardGate, isFalse);
      expect(reference.hardGate, isFalse);
      expect(shipping.controlStage.label, '发货参考');
      expect(shipping.controlStage.description, contains('不预留包材、不阻止实际发货'));
      expect(shipping.controlStage.description, contains('FINISH'));
      expect(shipping.controlStage.description, contains('PER_PACKAGE'));
      expect(shipping.controlStage.description, contains('FIXED_BATCH'));
    },
  );

  test('ADR-129 actual usage fields parse and format without float noise', () {
    final item = GoodsBomItem.fromJson({
      'id': 'row-3',
      'componentGoodsId': 'component-3',
      'qty': 0.1,
      'actualQty': 0.10500000000000001,
      'actualPerUnitQty': 0.105,
      'actualStatus': 'ACTUAL',
      'usageBasis': 'ACTUAL',
      'actualSampleCount': 3,
      'actualOutputQty': 400,
      'actualNetQty': 42,
      'actualUpdatedAt': '2026-09-26T10:00:00+08:00',
      'relearnedAt': '2026-09-20T02:00:00Z',
      'systemLearned': true,
    });

    expect(item.systemLearned, isTrue);
    expect(item.actual.status, BomActualStatus.actual);
    expect(item.actual.usesActual, isTrue);
    expect(item.actual.sampleCount, 3);
    expect(item.actual.outputQty, 400);
    expect(item.actual.netQty, 42);
    expect(item.actual.relearnedAt, DateTime.utc(2026, 9, 20, 10));
    expect(item.designQtyText, '0.1');
    expect(item.actualQtyText, '0.105');
    expect(formatBomQty(0.00001), '0.00001');
    expect(formatBomQty(1e-7), '0');
    expect(formatBomQty(100), '100');
  });

  test('daily report defects parse with the actual usage', () {
    // 不良只作说明：真实使用数量仍按良品，另给实产单耗与不良率。
    final item = GoodsBomItem.fromJson({
      'id': 'row-5',
      'componentGoodsId': 'component-5',
      'qty': 0.1,
      'actualQty': 0.105,
      'actualStatus': 'ACTUAL',
      'usageBasis': 'ACTUAL',
      'actualNetQty': 42,
      'actualOutputQty': 400,
      'actualSampleCount': 3,
      'actualDefectQty': 20,
      'actualPerProducedQty': 0.1,
      'actualDefectRate': 0.047619,
    });
    expect(item.actual.qty, 0.105);
    expect(item.actual.defectQty, 20);
    expect(item.actual.perProducedQty, 0.1);
    expect(item.actual.defectRate, 0.047619);

    // 没有不良/没有产出：不良数 0，实产单耗与不良率为空。
    final none = BomActualUsage.fromJson({
      'actualStatus': 'NO_DATA',
      'actualDefectQty': 0,
      'actualPerProducedQty': null,
      'actualDefectRate': null,
    });
    expect(none.defectQty, 0);
    expect(none.perProducedQty, isNull);
    expect(none.defectRate, isNull);
    expect(BomActualUsage.none.defectQty, 0);
  });

  test('defect rate shows as a percent with at most two decimals', () {
    expect(formatBomDefectRate(0.0325), '3.25%');
    expect(formatBomDefectRate(0.1), '10%');
    expect(formatBomDefectRate(0), '0%');
    expect(formatBomDefectRate(1), '100%');
    expect(formatBomDefectRate(0.047619), '4.76%');
    expect(formatBomDefectRate(0.00001), '<0.01%');
    expect(formatBomDefectRate(0.125), '12.5%');
  });

  test('legacy BOM rows have no actual usage and show a dash', () {
    final item = GoodsBomItem.fromJson({
      'id': 'row-4',
      'componentGoodsId': 'component-4',
      'qty': 2,
      'actualStatus': 'NOT_LINEAR',
      'usageBasis': 'DESIGN',
    });

    expect(item.systemLearned, isFalse);
    expect(item.actual.qty, isNull);
    expect(item.actual.status, BomActualStatus.notLinear);
    expect(item.actual.usesActual, isFalse);
    expect(item.actualQtyText, '—');
    expect(BomActualStatus.fromCode('SOMETHING_NEW'), isNull);
  });

  test('learning summary parses profile and component groups', () {
    // 学习记录组件行与组装信息行用同一组 actual* 字段(同一个解析)。
    final summary = GoodsBomLearningSummary.fromJson({
      'canRelearn': true,
      'profile': {
        'totalOutputQty': 400,
        'sampleCount': 2,
        'totalDefectQty': 12.5,
        'blockedReason': 'BOM_CYCLE',
        'outputUnitName': '个',
      },
      'components': [
        {
          'componentGoodsId': 'glue',
          'inBom': false,
          'released': true,
          'actualQty': 0.02,
          'actualPerUnitQty': 0.02,
          'actualStatus': 'ACTUAL',
          'actualNetQty': 8,
          'actualOutputQty': 400,
          'actualSampleCount': 2,
          'actualUpdatedAt': '2026-09-26T10:00:00+08:00',
        },
      ],
    });

    expect(summary.canRelearn, isTrue);
    expect(summary.profile?.totalOutputQty, 400);
    expect(summary.profile?.totalDefectQty, 12.5);
    expect(summary.profile?.blockedReason, 'BOM_CYCLE');
    final glue = summary.components.single;
    expect(glue.released, isTrue);
    expect(glue.inBom, isFalse);
    expect(glue.designQty, isNull);
    expect(glue.actual.qty, 0.02);
    expect(glue.actual.status, BomActualStatus.actual);
    expect(glue.actual.usesActual, isFalse, reason: 'BOM 外的料不参与计算');
    expect(glue.actual.netQty, 8);
    expect(glue.actual.outputQty, 400);
    expect(glue.actual.sampleCount, 2);
    expect(glue.actual.updatedAt, isNotNull);
    final empty = GoodsBomLearningSummary.fromJson({});
    expect(empty.profile, isNull);
    expect(empty.canRelearn, isFalse, reason: '服务端没说能重学就不给按钮');
  });

  test('design reason codes map to one plain-language text', () {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(bomDesignReasonText(l10n, 'NO_DATA'), '还没有已完工且核清余料的生产数据');
    expect(bomDesignReasonText(l10n, 'NOT_LINEAR'), '整包或固定批次不能按平均用量算');
    expect(bomDesignReasonText(l10n, 'OUTPUT_UNIT_CHANGED'), '父件单位变了，需重新学习');
    expect(
      bomDesignReasonText(l10n, 'SUBCONTRACT_OUTBOUND'),
      '本次由委外单一子件发料，按委外合同用量',
    );
    expect(bomDesignReasonText(l10n, null), '没有可用的真实数据');
    expect(bomDesignReasonText(l10n, 'SOMETHING_NEW'), '没有可用的真实数据');
    // 英文/韩文同样不外露内部代码。
    for (final locale in const [Locale('en'), Locale('ko')]) {
      final other = lookupAppLocalizations(locale);
      for (final code in [
        'NO_DATA',
        'NOT_LINEAR',
        'OUTPUT_UNIT_CHANGED',
        'SUBCONTRACT_OUTBOUND',
        null,
      ]) {
        final text = bomDesignReasonText(other, code);
        expect(text, isNotEmpty);
        expect(text, isNot(contains('_')), reason: '$locale $code');
      }
    }
  });
}
