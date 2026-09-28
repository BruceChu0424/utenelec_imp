// 车间内料仓设置页 (ADR-131 §5.1, 实现规格 §5.4):
// 批量新增 21 台; 勾选多行改容量一格批量生效 (看到的勾选 = 提交的内容);
// 上线准备按克输入、异常单重二次确认、与货品资料单重差 20% 标黄;
// "勾选行用货品资料单重填入"只填空着的行并标黄。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_setup_page.dart';

import 'workshop_material_test_support.dart';

WmMachine _machine(int i) => WmMachine(
  id: 'm$i',
  code: 'ZS${i.toString().padLeft(2, '0')}',
  name: '$i 号机',
  sortOrder: i,
  containers: [
    WmContainer(
      id: 'm$i-hopper',
      machineId: 'm$i',
      name: '干燥机料斗',
      capacityQty: 50,
      rowVersion: 2,
    ),
    WmContainer(
      id: 'm$i-barrel',
      machineId: 'm$i',
      name: '储料桶',
      capacityQty: 100,
      sortOrder: 1,
      rowVersion: 2,
    ),
  ],
);

FakeWorkshopMaterialRepository _repo() => FakeWorkshopMaterialRepository()
  ..settingsResult = const [wmTestWorkshop]
  ..machinesByWorkshop = {
    'w1': [_machine(1), _machine(2), _machine(3)],
  }
  ..materialsByWorkshop = const {
    'w1': [wmTestPp],
  }
  ..preparationByWorkshop = const {
    'w1': WmPreparation(
      total: 3,
      chosen: 1,
      weighed: 1,
      // 可选的料随清单下发 (本车间内料仓收的整批领料主料)。
      materials: [wmTestPp],
      rows: [
        WmPreparationRow(
          productGoodsId: 'P1',
          productCode: 'CP-001',
          productName: '外壳',
          legacyMaterial: 'PP',
          materialGoodsId: 'pp',
          materialSource: 'CHOICE',
          goodsWeightGrams: 12,
          status: 'CHOSEN',
        ),
        WmPreparationRow(
          productGoodsId: 'P2',
          productCode: 'CP-002',
          productName: '底座',
          bomItemId: 'bom-P2',
          materialGoodsId: 'pp',
          materialSource: 'BOM',
          unitWeightGrams: 5,
          goodsWeightGrams: 8,
          status: 'WEIGHED',
        ),
        WmPreparationRow(
          productGoodsId: 'P3',
          productCode: 'CP-003',
          productName: '旋钮',
          status: 'PENDING',
        ),
      ],
    ),
  };

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const Key('wm-setup-tabs')),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// 行首勾选框 (表头全选是三态框, 这里只取行上的)。
Finder _rowCheckboxes() =>
    find.byWidgetPredicate((w) => w is Checkbox && !w.tristate);

TextEditingController _controller(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!;

void main() {
  testWidgets('批量新增机台: 默认 21 台, 每台干燥机料斗 50 + 储料桶 100', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: repo,
      size: const Size(1600, 1000),
    );
    await _openTab(tester, '机台与容器');

    await tester.tap(find.byKey(const Key('wm-machines-batch-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-batch-confirm')));
    await tester.pumpAndSettle();

    expect(repo.createMachineCalls, hasLength(1));
    final call = repo.createMachineCalls.single;
    expect(call.workshopId, 'w1');
    expect(call.count, 21);
    expect(call.startNo, 4);
    expect(call.containers.map((c) => c.name), ['干燥机料斗', '储料桶']);
    expect(call.containers.map((c) => c.capacityQty), [50, 100]);
  });

  testWidgets('勾选两行改一格容量, 两行一起改, 没勾的不动, 提交的就是这两行', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: repo,
      size: const Size(1600, 1000),
    );
    await _openTab(tester, '机台与容器');

    expect(_rowCheckboxes(), findsNWidgets(3));
    await tester.tap(_rowCheckboxes().at(0));
    await tester.pump();
    await tester.tap(_rowCheckboxes().at(1));
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('wm-machine-cap-m1-干燥机料斗')),
      '60',
    );
    await tester.pump();

    expect(_controller(tester, 'wm-machine-cap-m1-干燥机料斗').text, '60');
    expect(_controller(tester, 'wm-machine-cap-m2-干燥机料斗').text, '60');
    expect(_controller(tester, 'wm-machine-cap-m3-干燥机料斗').text, '50');
    expect(_controller(tester, 'wm-machine-cap-m1-储料桶').text, '100');

    await tester.ensureVisible(find.byKey(const Key('wm-machines-save')));
    await tester.tap(find.byKey(const Key('wm-machines-save')));
    await tester.pumpAndSettle();

    expect(repo.machineUpdates, isEmpty);
    expect(repo.containerUpdates, hasLength(1));
    final items = repo.containerUpdates.single;
    expect(items.map((i) => i['id']), ['m1-hopper', 'm2-hopper']);
    expect(items.every((i) => i['capacityQty'] == 60), isTrue);
    expect(items.every((i) => i['expectedVersion'] == 2), isTrue);
  });

  testWidgets('上线准备: 一键填入只填空着的勾选行并标黄; 差 20% 也标黄', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: repo,
      size: const Size(1600, 1000),
    );
    await _openTab(tester, '上线准备');

    expect(find.text('常做的 3 个产品, 已选料 1 个, 已填单重 1 个'), findsOneWidget);
    // P2 单重 5 克, 货品资料 8 克, 差 37.5% → 标黄。
    expect(find.byKey(const Key('wm-prep-flag-P2')), findsOneWidget);
    expect(find.byKey(const Key('wm-prep-flag-P1')), findsNothing);

    // 全选后一键填入。
    await tester.tap(
      find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('wm-prep-fill-goods-weight')));
    await tester.pumpAndSettle();

    // P1 空着且货品资料有单重 → 填 12 并标黄; P2 已有单重不动; P3 没有参考值不填。
    expect(_controller(tester, 'wm-prep-grams-P1').text, '12');
    expect(find.byKey(const Key('wm-prep-flag-P1')), findsOneWidget);
    expect(_controller(tester, 'wm-prep-grams-P2').text, '5');
    expect(_controller(tester, 'wm-prep-grams-P3').text, '');
  });

  testWidgets('上线准备: 按克输入, 超过 5000 克先确认再保存', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: repo,
      size: const Size(1600, 1000),
    );
    await _openTab(tester, '上线准备');

    await tester.tap(find.byKey(const Key('wm-prep-material-P3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PP 颗粒').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('wm-prep-grams-P3')), '6000');
    await tester.pump();

    await tester.tap(find.byKey(const Key('wm-prep-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('单个重量 6000 克看起来不太对'), findsOneWidget);
    expect(repo.preparationSaves, isEmpty);

    await tester.tap(find.text('确定没错'));
    await tester.pumpAndSettle();

    expect(repo.preparationSaves, hasLength(1));
    final save = repo.preparationSaves.single;
    // 认料记在本车间名下; 异常单重的确认逐行带。
    expect(save.workshopId, 'w1');
    expect(save.rows, hasLength(1));
    expect(save.rows.single['productGoodsId'], 'P3');
    expect(save.rows.single['materialGoodsId'], 'pp');
    expect(save.rows.single['unitWeightGrams'], 6000);
    expect(save.rows.single['confirmUnusualWeight'], isTrue);
    expect(save.rows.single.containsKey('bomItemId'), isFalse);
  });

  testWidgets('上线准备: 改已有 BOM 单重的行带上 BOM 行号; 已填单重的不能清空只选料', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: repo,
      size: const Size(1600, 1000),
    );
    await _openTab(tester, '上线准备');

    await tester.enterText(find.byKey(const Key('wm-prep-grams-P2')), '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wm-prep-save')));
    await tester.pumpAndSettle();
    // 页面先拦下 (服务端也会拒): 已有 BOM 单重的产品不能只选料。
    expect(repo.preparationSaves, isEmpty);

    await tester.enterText(find.byKey(const Key('wm-prep-grams-P2')), '7.5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wm-prep-save')));
    await tester.pumpAndSettle();

    expect(repo.preparationSaves, hasLength(1));
    final row = repo.preparationSaves.single.rows.single;
    expect(row['productGoodsId'], 'P2');
    expect(row['bomItemId'], 'bom-P2');
    expect(row['unitWeightGrams'], 7.5);
    expect(row.containsKey('confirmUnusualWeight'), isFalse);
  });

  testWidgets('上线准备: 服务端要人确认第二种料时弹框, 确认后带上确认重发', (tester) async {
    final repo = _repo()
      ..preparationFailureOnce = ApiException(
        'VALIDATION_FAILED',
        '「外壳」要同时用两种料吗 (双色 / 双料)?',
        fieldErrors: const [
          ApiFieldError(
            field: 'confirmSecondPeriodicMaterial',
            message: '「外壳」要同时用两种料吗 (双色 / 双料)?',
          ),
        ],
      );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: repo,
      size: const Size(1600, 1000),
    );
    await _openTab(tester, '上线准备');

    await tester.enterText(find.byKey(const Key('wm-prep-grams-P1')), '12');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wm-prep-save')));
    await tester.pumpAndSettle();

    expect(repo.preparationSaves, isEmpty);
    expect(find.textContaining('要同时用两种料吗'), findsWidgets);
    await tester.tap(find.byKey(const Key('periodic-bom-confirm')));
    await tester.pumpAndSettle();

    expect(repo.preparationSaves, hasLength(1));
    final row = repo.preparationSaves.single.rows.single;
    expect(row['productGoodsId'], 'P1');
    expect(row['unitWeightGrams'], 12);
    expect(row['confirmSecondPeriodicMaterial'], isTrue);
  });
}
