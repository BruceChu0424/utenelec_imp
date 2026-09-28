// 盘点页 (手机优先, ADR-131 §5.7, 实现规格 §5.4):
// 21 台机卡片渲染、满/半/空每台 2 下; "本机停机、全空"; "其余记 0";
// 逐行保存 409 回显最新值; 窄屏 (375) 与大字体无截断。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_count_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/machine_count_card.dart';

import 'workshop_material_test_support.dart';

const _pp = WmCountMaterial(
  goodsId: 'pp',
  goodsName: 'PP 颗粒',
  bulkPackageQty: 25,
);

List<WmCountMachine> _machines(int n) => [
  for (var i = 1; i <= n; i++)
    WmCountMachine(
      machineId: 'm$i',
      name: '$i 号机',
      code: 'ZS$i',
      sortOrder: i,
      lastGoodsId: 'pp',
      containers: [
        WmCountContainer(
          containerId: 'm$i-hopper',
          name: '干燥机料斗',
          capacityQty: 50,
        ),
        WmCountContainer(
          containerId: 'm$i-barrel',
          name: '储料桶',
          capacityQty: 100,
          sortOrder: 1,
        ),
      ],
    ),
];

FakeWorkshopMaterialRepository _repo({int machines = 21}) {
  final count = WmCount(
    id: 'c1',
    periodId: 'p1',
    status: 'DRAFT',
    machines: _machines(machines),
    materials: const [_pp],
    allowedActions: const ['EDIT_COUNT', 'SUBMIT_COUNT'],
  );
  return FakeWorkshopMaterialRepository()
    ..periodById = const {
      'p1': WmPeriod(
        id: 'p1',
        periodNo: 3,
        startDate: '2026-09-01',
        endDate: '2026-09-28',
        status: 'COUNTING',
        currentCountId: 'c1',
        allowedActions: ['WITHDRAW_COUNT'],
      ),
    }
    ..countById = {'c1': count};
}

Set<String>? _selected(WidgetTester tester, String containerId) => tester
    .widget<SegmentedButton<String>>(find.byKey(Key('wm-fill-$containerId')))
    .selected;

void main() {
  testWidgets('21 台机卡片都在, 每台点 2 下就录完', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      // 两列卡片一屏放下全部 21 台 (ListView 只建可见的卡)。
      size: const Size(1400, 4200),
    );

    expect(find.byType(MachineCountCard), findsNWidgets(21));
    expect(find.text('已录 0 / 42 个容器, 0 / 1 种袋料'), findsOneWidget);

    for (var i = 1; i <= 21; i++) {
      await tester.tap(find.byKey(Key('wm-fill-m$i-hopper-FULL')));
      await tester.tap(find.byKey(Key('wm-fill-m$i-barrel-HALF')));
    }
    await tester.pumpAndSettle();

    // 在用料默认上次, 所以每台只点两下: 21 × 2 = 42 次逐行保存。
    expect(repo.savedLines, hasLength(42));
    expect(repo.savedLines.every((l) => l.goodsId == 'pp'), isTrue);
    expect(
      repo.savedLines.where((l) => l.fillLevel == WmFillLevel.full),
      hasLength(21),
    );
    expect(
      repo.savedLines.where((l) => l.fillLevel == WmFillLevel.half),
      hasLength(21),
    );
    expect(find.text('已录 42 / 42 个容器, 0 / 1 种袋料'), findsOneWidget);
    expect(_selected(tester, 'm7-barrel'), {WmFillLevel.half});
  });

  testWidgets('本机停机、全空一键记两个空容器; 其余料记 0', (tester) async {
    final repo = _repo(machines: 2);
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
    );

    await tester.tap(find.byKey(const Key('wm-machine-idle-m1')));
    await tester.pumpAndSettle();
    expect(repo.savedLines, hasLength(2));
    expect(
      repo.savedLines.every(
        (l) => l.fillLevel == WmFillLevel.empty && l.machineId == 'm1',
      ),
      isTrue,
    );
    expect(_selected(tester, 'm1-hopper'), {WmFillLevel.empty});
    expect(_selected(tester, 'm1-barrel'), {WmFillLevel.empty});

    final zero = find.byKey(const Key('wm-count-zero-rest'));
    await tester.ensureVisible(zero);
    await tester.tap(zero);
    await tester.pumpAndSettle();
    expect(repo.zeroRestCalls, hasLength(1));
    expect(find.textContaining('1 / 1 种袋料'), findsOneWidget);
  });

  testWidgets('逐行保存撞上别人刚改过 (409): 重拉并显示最新的数', (tester) async {
    final repo = _repo(machines: 2);
    final base = repo.countById['c1']!;
    repo
      ..conflictOnce.add('m1-hopper')
      ..countAfterConflict = WmCount(
        id: 'c1',
        periodId: 'p1',
        status: 'DRAFT',
        machines: base.machines,
        materials: base.materials,
        allowedActions: base.allowedActions,
        lines: const [
          WmCountLine(
            id: 'l-other',
            clientLineKey: 'C:m1-hopper',
            lineKind: WmLineKind.container,
            goodsId: 'pp',
            machineId: 'm1',
            containerId: 'm1-hopper',
            capacityQtySnapshot: 50,
            fillLevel: WmFillLevel.half,
            qtyBase: 25,
            rowVersion: 3,
          ),
        ],
      );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
    );

    await tester.tap(find.byKey(const Key('wm-fill-m1-hopper-FULL')));
    await tester.pumpAndSettle();

    expect(repo.savedLines, hasLength(1));
    // 页面回显的是别人刚存的"半", 不是自己点的"满"。
    expect(_selected(tester, 'm1-hopper'), {WmFillLevel.half});
    expect(find.byKey(const Key('wm-container-qty-m1-hopper')), findsOneWidget);
    expect(find.text('25 公斤'), findsOneWidget);
    expect(
      find.byKey(const Key('wm-container-error-m1-hopper')),
      findsOneWidget,
    );
  });

  testWidgets('窄屏 375 + 大字体: 卡片不截断、不溢出', (tester) async {
    final repo = _repo(machines: 3);
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      size: const Size(375, 812),
      textScale: 1.3,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(MachineCountCard), findsWidgets);
    // 一路滚到底, 途经的每张卡与袋料卡都不能溢出。
    await tester.drag(
      find.byKey(const Key('wm-count-list')),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('wm-count-submit')), findsOneWidget);
  });
}
