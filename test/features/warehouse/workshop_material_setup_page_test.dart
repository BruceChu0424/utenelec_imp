// 车间内料仓设置页 (ADR-131 §5.1, 实现规格 §5.4; ADR-147 起只剩机台与容器、上线准备两个页签,
// 开通/开启整批领料在内料仓总览里批量办):
// 批量新增 21 台; 勾选多行改容量一格批量生效 (看到的勾选 = 提交的内容);
// 上线准备按克输入、异常单重二次确认、与货品资料单重差 20% 标黄;
// "勾选行用货品资料单重填入"只填空着的行并标黄。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_setup_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_machines_tab.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_prep_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'workshop_material_test_support.dart';

class _StubSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _SetupRepository extends FakeWorkshopMaterialRepository {
  int preparationReads = 0;

  @override
  Future<WmPreparation> preparation(String workshopId) {
    preparationReads++;
    return super.preparation(workshopId);
  }
}

Future<ProviderContainer> _pumpSetupPage(
  WidgetTester tester,
  Widget page, {
  required FakeWorkshopMaterialRepository repo,
  Size size = const Size(1400, 900),
  Set<String> permissions = const {Perm.workshopMaterialSetup, Perm.goodsView},
  StateProvider<Set<String>>? livePermissions,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(() => _StubSession()),
      apiBaseUrlProvider.overrideWithValue('https://workshop.test/api'),
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentPermissionsProvider.overrideWith(
        (ref) =>
            livePermissions == null ? permissions : ref.watch(livePermissions),
      ),
      isSuperAdminProvider.overrideWithValue(false),
      fixedBadgeSummaryOverride(),
      workshopMaterialRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

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

_SetupRepository _repo() => _SetupRepository()
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
  testWidgets('仅设置权限只有机台页签，隐藏上线准备且不读取产品资料; 不再有车间开启页签', (tester) async {
    final repo = _repo();
    await _pumpSetupPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: repo,
      permissions: {Perm.workshopMaterialSetup},
    );
    expect(find.text('上线准备'), findsNothing);
    expect(find.text('车间开启'), findsNothing);
    expect(find.byType(WmMachinesTab), findsOneWidget);
    expect(repo.preparationReads, 0);
    expect(tester.takeException(), isNull);
  });

  for (final permissions in <Set<String>>[
    {Perm.workshopMaterialSetup},
    {Perm.goodsView},
  ]) {
    testWidgets('上线准备深链缺少配套权限时回机台页且零产品请求 $permissions', (tester) async {
      final repo = _repo();
      await _pumpSetupPage(
        tester,
        const WorkshopMaterialSetupPage(initialTab: 'prep'),
        repo: repo,
        permissions: permissions,
      );
      expect(find.text('上线准备'), findsNothing);
      expect(find.byType(WmPrepTab), findsNothing);
      expect(find.byType(WmMachinesTab), findsOneWidget);
      expect(repo.preparationReads, 0);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(repo.preparationReads, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('上线准备期间撤销货品查看权限会卸载产品表，刷新不会继续请求', (tester) async {
    final grants = StateProvider<Set<String>>(
      (_) => {Perm.workshopMaterialSetup, Perm.goodsView},
    );
    final repo = _repo();
    final container = await _pumpSetupPage(
      tester,
      const WorkshopMaterialSetupPage(initialTab: 'prep'),
      repo: repo,
      livePermissions: grants,
    );
    expect(find.byType(WmPrepTab), findsOneWidget);
    expect(repo.preparationReads, 1);
    container.read(grants.notifier).state = {Perm.workshopMaterialSetup};
    await tester.pumpAndSettle();
    expect(find.byType(WmPrepTab), findsNothing);
    expect(find.text('上线准备'), findsNothing);
    expect(find.byType(WmMachinesTab), findsOneWidget);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(repo.preparationReads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit workshop is preserved across setup tabs and reload', (
    tester,
  ) async {
    final repo = _repo()
      ..settingsResult = const [
        WmSetting(
          workshopDepartmentId: 'other',
          workshopName: '另一车间',
          status: WmBinStatus.periodic,
          periodicEnabled: true,
          binWarehouseId: 'other-bin',
        ),
        wmTestWorkshop,
      ];
    await _pumpSetupPage(
      tester,
      const WorkshopMaterialSetupPage(initialWorkshopId: 'w1'),
      repo: repo,
      size: const Size(1600, 1000),
    );
    // 车间切换与内料仓总览同一份清单; 深链的车间保持选中。
    expect(
      find.descendant(
        of: find.byKey(const Key('wm-setup-workshop')),
        matching: find.text('另一车间'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<WmMachinesTab>(find.byType(WmMachinesTab)).workshopId,
      'w1',
    );
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    await _openTab(tester, '机台与容器');
    final machines = tester.widget<WmMachinesTab>(find.byType(WmMachinesTab));
    expect(machines.workshopId, 'w1');
    await _openTab(tester, '上线准备');
    final preparation = tester.widget<WmPrepTab>(find.byType(WmPrepTab));
    expect(preparation.workshopId, 'w1');
  });

  testWidgets('unavailable requested workshop does not show another setup', (
    tester,
  ) async {
    await _pumpSetupPage(
      tester,
      const WorkshopMaterialSetupPage(initialWorkshopId: 'not-visible'),
      repo: _repo(),
    );
    expect(find.text('指定车间当前不可用或无权查看'), findsOneWidget);
    expect(find.text('注塑车间'), findsNothing);
    expect(find.byType(WmMachinesTab), findsNothing);
  });

  testWidgets('上线余料说明明确原账衔接且不为工单重新领料', (tester) async {
    await _pumpSetupPage(
      tester,
      const WorkshopMaterialSetupPage(),
      repo: _repo(),
      size: const Size(800, 900),
    );
    await _openTab(tester, '上线准备');
    await tester.tap(find.byKey(const Key('wm-setup-opening-guide')));
    await tester.pumpAndSettle();
    expect(find.text('上线前清点车间余料'), findsOneWidget);
    expect(find.textContaining('不要求生产员工为每张工单重新领料'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('上线前清点车间余料'), findsNothing);
  });

  testWidgets(
    'machine and preparation facts retain raw inputs and their listeners',
    (tester) async {
      await _pumpSetupPage(
        tester,
        const WorkshopMaterialSetupPage(),
        repo: _repo(),
        size: const Size(1600, 1000),
      );
      await _openTab(tester, '机台与容器');
      final machines = tester.widget<UtenEditableGrid<WmMachineRow>>(
        find.byType(UtenEditableGrid<WmMachineRow>),
      );
      final machine = machines.controller.rows.first;
      final tonnage = machines.columns.singleWhere(
        (column) => column.key == 'tonnage',
      );
      final order = machines.columns.singleWhere(
        (column) => column.key == 'sortOrder',
      );
      expect(tonnage.exactListenableOf!(machine), same(machine.tonnage));
      expect(order.exactListenableOf!(machine), same(machine.sortOrder));
      machine.tonnage.text = '123.0000000001';
      machine.sortOrder.text = '7';
      expect(tonnage.exactValueOf!(machine), '123.0000000001');
      expect(order.exactValueOf!(machine), '7');
      expect(machine.machine.tonnage, isNull);
      // Container names have no stable registered fact identity; never invent
      // positional aliases which could point to another container after reorder.
      expect(
        machines.columns.where((column) => column.key.startsWith('cap-')),
        everyElement(
          isA<EditableGridColumn<WmMachineRow>>().having(
            (column) => column.exactValueOf,
            'no invented container fact',
            isNull,
          ),
        ),
      );

      await _openTab(tester, '上线准备');
      final preparations = tester.widget<UtenEditableGrid<WmPrepRow>>(
        find.byType(UtenEditableGrid<WmPrepRow>),
      );
      final row = preparations.controller.rows.first;
      final grams = preparations.columns.singleWhere(
        (column) => column.key == 'grams',
      );
      final reference = preparations.columns.singleWhere(
        (column) => column.key == 'goodsWeight',
      );
      expect(grams.exactListenableOf!(row), same(row.grams));
      row.grams.text = '1.23456789';
      expect(grams.exactValueOf!(row), '1.23456789');
      expect(reference.exactValueOf!(row), '12.0');
      row.grams.clear();
      expect(grams.exactValueOf!(row), isEmpty);
      expect(row.source.unitWeightGrams, isNull);
    },
  );

  testWidgets('批量新增机台: 默认 21 台, 每台干燥机料斗 50 + 储料桶 100', (tester) async {
    final repo = _repo();
    await _pumpSetupPage(
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
    await _pumpSetupPage(
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
    await _pumpSetupPage(
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
    await _pumpSetupPage(
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
    await _pumpSetupPage(
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
    await _pumpSetupPage(
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
