import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_quantity_apportionment.dart';

void main() {
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

  group('coarsestDisplayScale', () {
    test('整数计量最粗到 0：1000.0002 的尾巴收敛成整数', () {
      const parts = [83.3334, 83.3333, 833.3333];
      expect(coarsestDisplayScale(1000.0002, parts), 0);
    });

    test('单路径 0.75 在整数粒度内（展示口径 CEILING 保守向上）', () {
      expect(coarsestDisplayScale(0.75, [0.75]), 0);
      expect(apportionLargestRemainder(0.75, [0.75], 0), [1]);
    });

    test('正量不能被粗化抹成 0：0.001 退到千分位', () {
      expect(coarsestDisplayScale(0.001, [0.0005, 0.0005]), 3);
      expect(apportionLargestRemainder(0.001, [0.0005, 0.0005], 3), [0.001, 0]);
    });

    test('真分数值保留小数：0.4 用不到整数粒度', () {
      expect(coarsestDisplayScale(0.4, [0.4]), 1);
      expect(coarsestDisplayScale(0.045, [0.045]), 2);
    });

    test('空列表最粗为 0；总量为 0 也为 0', () {
      expect(coarsestDisplayScale(0, []), 0);
      expect(coarsestDisplayScale(0, [0, 0]), 0);
      expect(coarsestDisplayScale(0.00003, [0.00003]), 4);
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
