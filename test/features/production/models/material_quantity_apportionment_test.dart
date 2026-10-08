import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_quantity_apportionment.dart';

void main() {
  group('splitTypedTotalText request precision', () {
    test('默认起订量倍数和来源单位换算始终按原始十进制事实计算', () {
      const quantity = '9999999999999.9999';
      expect(
        materialQuantityWithOrderPolicy('1000', quantity, '0.0001'),
        quantity,
      );
      expect(materialQuantityWithOrderPolicy('1.0001', '0', '0.3'), '1.2');
      expect(materialQuantityProduct(quantity, '3'), '29999999999999.9997');
      expect(materialQuantityQuotient('29999999999999.9997', '3'), quantity);
      expect(materialQuantityQuotient('0.1234', '0.000001'), '123400');
      expect(materialUnitRateFact(null, 0.00032), '0.00032');
      expect(
        materialQuantityProduct('100000', materialUnitRateFact(null, 0.00032)),
        '32',
      );
      expect(
        () => materialUnitRateFact(null, 1000000000.000001),
        throwsFormatException,
      );
      expect(() => materialQuantityQuotient('1', '3'), throwsFormatException);
    });
    test('合法14位整数边界与万分位均原样守恒', () {
      for (final total in [
        '4500.0001',
        '999999999999.9999',
        '9999999999999.9999',
        '99999999999999.9999',
      ]) {
        final shares = splitTypedTotalText(total, ['1000', '1000', '1000']);
        expect(
          shares.map(materialQuantityUnits).fold(BigInt.zero, (a, b) => a + b),
          materialQuantityUnits(total),
          reason: '$total -> $shares',
        );
      }
      expect(
        splitTypedTotalText('999999999999.9999', ['1000', '1000', '1000']),
        ['333333333333.3333', '333333333333.3333', '333333333333.3333'],
      );
    });

    test('整数编辑和有需求优先的平分语义保持一致', () {
      expect(splitTypedTotalText('4500', ['1000', '1000', '1000']), [
        '1500',
        '1500',
        '1500',
      ]);
      expect(splitTypedTotalText('1000', ['83.3334', '83.3334', '833.3334']), [
        '84',
        '83',
        '833',
      ]);
      expect(splitTypedTotalText('10', ['0', '1', '1']), ['0', '5', '5']);
      expect(splitTypedTotalText('1', ['0', '0', '0']), ['1', '0', '0']);
      expect(splitTypedTotalText('0', ['1000', '1000']), ['0', '0']);
      expect(splitTypedTotalText('3.', ['1', '1']), ['2', '1']);
    });

    test('不足量按精确余数分摊且拒绝丢失超出4位的小数', () {
      expect(splitTypedTotalText('0.0001', ['99999999999999.9998', '0.0001']), [
        '0.0001',
        '0',
      ]);
      expect(splitTypedTotalText('0.0002', ['1', '1', '1']), [
        '0.0001',
        '0.0001',
        '0',
      ]);
      expect(
        () => splitTypedTotalText('1.00001', ['1']),
        throwsFormatException,
      );
      expect(() => splitTypedTotalText('-1', ['1']), throwsFormatException);
    });
  });

  group('apportionLargestRemainder', () {
    test('空列表返回空且不参与守恒', () {
      expect(apportionLargestRemainder(100, [], 0), isEmpty);
      expect(splitTypedTotal(100, [], 2), isEmpty);
    });

    test('权重全零时均分，余数按索引序 +1', () {
      expect(apportionLargestRemainder(1000, [0, 0, 0], 0), [334, 333, 333]);
      expect(apportionLargestRemainder(900, [0, 0, 0], 0), [300, 300, 300]);
    });

    test('服务端 1e-4 分摊尾巴在整数粒度整分成 84/83/833', () {
      expect(
        apportionLargestRemainder(1000.0002, [83.3334, 83.3333, 833.3333], 0),
        [84, 83, 833],
      );
    });

    test('守恒不变量：Σ份额恒等于该 scale 下对总量的取整值', () {
      const cases = [
        (1000.0002, [83.3334, 83.3333, 833.3333]),
        (0.75, [0.75]),
        (6000.0, [1000.0, 1000.0, 1000.0]),
        (12.3456, [1.1111, 2.2222, 3.3333, 5.5555]),
        (0.001, [0.0005, 0.0005]),
      ];
      for (final (total, weights) in cases) {
        for (final scale in [0, 1, 2, 3, 4]) {
          final shares = apportionLargestRemainder(total, weights, scale);
          final sum = shares.fold<double>(0, (a, b) => a + b);
          // tick 整分本身精确守恒；逐份 double 再相加只允许 1e-9 级表示噪声。
          expect(
            sum,
            closeTo(roundToScale(total, scale), 1e-9),
            reason: 'total=$total scale=$scale',
          );
          for (final share in shares) {
            expect(share >= 0, isTrue, reason: 'scale=$scale');
          }
        }
      }
    });

    test('零权重份不参与分配', () {
      expect(apportionLargestRemainder(6000, [1000, 0, 1000, 1000], 0), [
        2000,
        0,
        2000,
        2000,
      ]);
    });

    test('4 位小数输入在 scale=4 原样整分', () {
      expect(apportionLargestRemainder(0.2468, [0.1234, 0.1234], 4), [
        0.1234,
        0.1234,
      ]);
      // 总量与各份之和一致时 scale=4 逐份原样（服务端 1e-4 分摊的落点）。
      expect(apportionLargestRemainder(1000, [83.3334, 83.3333, 833.3333], 4), [
        83.3334,
        83.3333,
        833.3333,
      ]);
    });
  });

  group('splitTypedTotal', () {
    test('总量盖住 ceil 合计：先给足 ceil 再均分富余', () {
      expect(splitTypedTotal(1002, [83.3334, 83.3333, 833.3333], 0), [
        84,
        84,
        834,
      ]);
      // 富余 3000 在三条有需求的来源间均分（连通口径的 6000/3=2000 例）。
      expect(splitTypedTotal(6000, [1000, 1000, 1000], 0), [2000, 2000, 2000]);
    });

    test('总量低于 ceil 合计：按需求权重整分', () {
      expect(splitTypedTotal(1000, [83.3334, 83.3333, 833.3333], 0), [
        84,
        83,
        833,
      ]);
    });

    test('零需求路径不被打扰，纯公共备货全体均分', () {
      expect(splitTypedTotal(900, [0, 0, 0], 0), [300, 300, 300]);
      expect(splitTypedTotal(3000, [0, 1000], 0), [0, 3000]);
      expect(splitTypedTotal(1500, [0, 1000], 0), [0, 1500]);
    });

    test('单路径：ceil 给足或按权重截到总量', () {
      expect(splitTypedTotal(100, [83.3334], 0), [100]);
      expect(splitTypedTotal(83.3334, [83.3334], 0), [83]);
      expect(splitTypedTotal(0.4, [0.4], 1), [0.4]);
    });

    test('守恒：Σ份额 == roundToScale(total, scale)', () {
      const cases = [
        (1002.0, [83.3334, 83.3333, 833.3333]),
        (1000.0, [83.3334, 83.3333, 833.3333]),
        (6000.0, [1000.0, 1000.0, 1000.0]),
        (0.2468, [0.1234, 0.1234]),
        (0.2, [0.1234, 0.1234]),
      ];
      for (final (total, needs) in cases) {
        for (final scale in [0, 1, 2, 3, 4]) {
          final shares = splitTypedTotal(total, needs, scale);
          expect(
            shares.fold<double>(0, (a, b) => a + b),
            closeTo(roundToScale(total, scale), 1e-9),
            reason: 'total=$total scale=$scale',
          );
        }
      }
    });

    test('4 位小数输入原样落格', () {
      expect(splitTypedTotal(0.2468, [0.1234, 0.1234], 4), [0.1234, 0.1234]);
      expect(splitTypedTotal(0.2467, [0.1234, 0.1234], 4), [0.1234, 0.1233]);
    });
  });

  group('roundToScale / ceilToScale', () {
    test('四舍五入与保守向上', () {
      expect(roundToScale(1000.0002, 0), 1000);
      expect(roundToScale(1000.5, 0), 1001);
      expect(ceilToScale(83.3334, 0), 84);
      expect(ceilToScale(83.3334, 4), 83.3334);
      expect(ceilToScale(0.1, 2), 0.1);
      expect(ceilToScale(0, 0), 0);
    });
  });
}
