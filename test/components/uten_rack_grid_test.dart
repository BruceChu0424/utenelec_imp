// UtenRackGrid 组件测试（货架图：库行 × 层 × 位）。
//
// 覆盖：布局→格子（层降序/位升序/空位弱化）、同格多货计数徽章、点格回调、
// 未分层桶平铺、空态、超大字号不溢出、lite 档零动画。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_rack_grid.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('布局→格子：层降序、位升序、空位弱化、有货格显编码', (tester) async {
    await _pump(
      tester,
      racks: const [
        UtenRackGridRack(rack: 'A31', maxLevel: 2, maxSlot: 2, count: 2),
      ],
      items: const [
        UtenRackGridItem(
          id: 'g1',
          place: 'A31-2-1',
          level: 2,
          slot: 1,
          code: 'GL-1001',
          name: '静音风扇电机',
          qtyLabel: '库存 12 只',
        ),
        UtenRackGridItem(
          id: 'g2',
          place: 'A31-1-2',
          level: 1,
          slot: 2,
          code: 'GL-1002',
          name: '风扇电容',
        ),
      ],
    );

    // 库行卡片 + 项数（服务端 count 优先）。
    expect(find.byKey(const Key('rack-card-A31')), findsOneWidget);
    expect(find.text('A31 库行'), findsOneWidget);
    expect(find.text('2 项'), findsOneWidget);

    // 2 层 × 2 位 = 4 格：2 格有货、2 格空位（空位画「—」）。
    expect(find.byKey(const Key('rack-cell-A31-2-1')), findsOneWidget);
    expect(find.byKey(const Key('rack-cell-A31-1-2')), findsOneWidget);
    expect(find.byKey(const Key('rack-cell-A31-2-2')), findsNothing);
    expect(find.byKey(const Key('rack-cell-A31-1-1')), findsNothing);
    expect(find.text('—'), findsNWidgets(2));

    expect(find.text('GL-1001'), findsOneWidget);
    expect(find.text('静音风扇电机'), findsOneWidget);
    expect(find.text('库存 12 只'), findsOneWidget);

    // 层标签高层在上（2 层的 y 小于 1 层）。
    final topLevel = tester.getTopLeft(find.text('2 层')).dy;
    final bottomLevel = tester.getTopLeft(find.text('1 层')).dy;
    expect(topLevel, lessThan(bottomLevel));
    // 位标签升序（1 位在 2 位左边）。
    expect(
      tester.getTopLeft(find.text('1 位')).dx,
      lessThan(tester.getTopLeft(find.text('2 位')).dx),
    );
  });

  testWidgets('同格多货品：首件出正文 + 「+n」计数徽章', (tester) async {
    await _pump(
      tester,
      racks: const [
        UtenRackGridRack(rack: 'A31', maxLevel: 1, maxSlot: 1, count: 3),
      ],
      items: const [
        UtenRackGridItem(
          id: 'g1',
          place: 'A31-1-1',
          level: 1,
          slot: 1,
          code: 'GL-1001',
          name: '静音风扇电机',
        ),
        UtenRackGridItem(
          id: 'g2',
          place: 'A31-1-1',
          level: 1,
          slot: 1,
          code: 'GL-1002',
          name: '风扇电容',
        ),
        UtenRackGridItem(
          id: 'g3',
          place: 'A31-1-1',
          level: 1,
          slot: 1,
          code: 'GL-1003',
          name: '风扇支架',
        ),
      ],
    );

    expect(find.text('GL-1001'), findsOneWidget);
    expect(find.text('GL-1002'), findsNothing); // 同格其余货品只计数不铺开
    expect(find.text('+2'), findsOneWidget);
  });

  testWidgets('点格回调回传库位号；选中格带无障碍 selected 语义', (tester) async {
    final tapped = <String>[];
    await _pump(
      tester,
      racks: const [
        UtenRackGridRack(rack: 'A31', maxLevel: 1, maxSlot: 2, count: 1),
      ],
      items: const [
        UtenRackGridItem(
          id: 'g1',
          place: 'A31-1-2',
          level: 1,
          slot: 2,
          code: 'GL-1002',
          name: '风扇电容',
        ),
      ],
      selectedPlace: 'A31-1-2',
      onCellTap: tapped.add,
    );

    await tester.tap(find.byKey(const Key('rack-cell-A31-1-2')));
    await tester.pumpAndSettle();
    expect(tapped, ['A31-1-2']);

    final semantics = tester.getSemantics(
      find.byKey(const Key('rack-cell-A31-1-2')),
    );
    expect(semantics.label, contains('库位 A31-1-2'));
    // flagsCollection.isSelected 是三态（Tristate），选中态断言其 isTrue 枚举值。
    expect(semantics.flagsCollection.isSelected.name, 'isTrue');
  });

  testWidgets('未分层桶：不画网格，平铺列表 + 指路文案', (tester) async {
    final tapped = <String>[];
    await _pump(
      tester,
      racks: const [UtenRackGridRack(rack: '', count: 2)],
      items: const [
        UtenRackGridItem(id: 'g1', place: '19', code: 'V20210', name: '面板'),
        UtenRackGridItem(id: 'g2', place: 'Y12', code: 'V51012', name: '底座'),
      ],
      onCellTap: tapped.add,
    );

    expect(find.byKey(const Key('rack-card-unparsed')), findsOneWidget);
    expect(find.text('未分层（2）'), findsOneWidget);
    expect(find.textContaining('请在货品资料改正'), findsOneWidget);
    expect(find.text('19'), findsOneWidget);
    expect(find.text('Y12'), findsOneWidget);

    await tester.tap(find.byKey(const Key('rack-unparsed-g2')));
    await tester.pumpAndSettle();
    expect(tapped, ['Y12']);
  });

  testWidgets('无库位数据：显示引导空态', (tester) async {
    await _pump(tester, racks: const [], items: const []);
    expect(find.byKey(const Key('rack-grid-empty')), findsOneWidget);
    expect(find.textContaining('暂无已维护库位号的货品'), findsOneWidget);
  });

  testWidgets('超大字号：格子随字号放大，不溢出', (tester) async {
    await _pump(
      tester,
      racks: const [
        UtenRackGridRack(rack: 'A31', maxLevel: 2, maxSlot: 3, count: 2),
      ],
      items: const [
        UtenRackGridItem(
          id: 'g1',
          place: 'A31-2-1',
          level: 2,
          slot: 1,
          code: 'GL-1001-LONG-CODE',
          name: '静音风扇电机（超长名称测试换行与省略）',
          qtyLabel: '库存 1234.5 只',
        ),
        UtenRackGridItem(
          id: 'g2',
          place: 'A31-1-3',
          level: 1,
          slot: 3,
          code: 'GL-1002',
          name: '风扇电容',
        ),
      ],
      textScale: 2.6,
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('rack-cell-A31-2-1')), findsOneWidget);
  });

  testWidgets('lite 档：格子无补间动画（duration 归零）', (tester) async {
    await _pump(
      tester,
      racks: const [
        UtenRackGridRack(rack: 'A31', maxLevel: 1, maxSlot: 1, count: 1),
      ],
      items: const [
        UtenRackGridItem(
          id: 'g1',
          place: 'A31-1-1',
          level: 1,
          slot: 1,
          code: 'GL-1001',
          name: '静音风扇电机',
        ),
      ],
      tier: PerformanceTier.lite,
    );

    final animated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const Key('rack-cell-A31-1-1')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(animated.duration, Duration.zero);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required List<UtenRackGridRack> racks,
  required List<UtenRackGridItem> items,
  String? selectedPlace,
  void Function(String place)? onCellTap,
  double textScale = 1,
  PerformanceTier tier = PerformanceTier.standard,
}) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        performanceProvider.overrideWith(() => _FixedTierNotifier(tier)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: SingleChildScrollView(
              child: UtenRackGrid(
                racks: racks,
                items: items,
                selectedPlace: selectedPlace,
                onCellTap: onCellTap,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 固定性能档（绕过设备探测，测 lite 档降级）。
class _FixedTierNotifier extends PerformanceNotifier {
  _FixedTierNotifier(this.tier);

  final PerformanceTier tier;

  @override
  PerformanceTier build() => tier;
}
