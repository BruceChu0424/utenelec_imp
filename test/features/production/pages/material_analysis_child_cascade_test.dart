// 「父件 + 下层一起下单」弹窗（ADR-081，2026-09-14 修订为弹窗前置）。
//
// 场景：成品A 本批需求 10，计划员按 20 下达（超产 10）。它的 BOM 是
//   成品A ─┬─ 外购件B  单件用 2（采购）
//          └─ 半成品C  单件用 1（自制）
//                └─ 外购件D  单件用 3（采购，孙层）
// 断言四件事：
//  1. 点「创建生产计划」后**先**弹「跟父件一起办」弹窗（父件还没提交），
//     树顶是本次要下达的件，按 BOM 自顶向下列出子层 / 孙层，数量按**本批 20**
//     而不是快照需求 10 算出来；
//  2. 一键下单按序提交：父件 issue-plans → 采购 notify BUY → 自制 issue-plans；
//  3. 下单数量按行内填写值提交，不是默认的剩余需求；
//  4. 基础需求已下过单的下层行：申请未分解的把追加量并入原申请（明细数量
//     改大，V477），已分解的问过「追加」后走 notify 超量通道另立追加申请。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

void main() {
  testWidgets('点创建生产计划先弹「跟父件一起办」，一键下单按序提交父件与下层', (tester) async {
    final harness = await _pump(tester);

    await _openWorkshopBucket(tester);

    // 本批数量改成 20（需求 10）——超产 10。
    await tester.enterText(_bucketQty('p1'), '20');
    await tester.pumpAndSettle();

    // 只勾选产品行（半成品C 那条自制候选留给下层办齐弹窗处理）。
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(find.textContaining('创建生产计划('));
    await tester.pumpAndSettle();
    // 超量二次确认。
    await tester.tap(find.text('确认超量下达'));
    await tester.pumpAndSettle();

    // 2026-09-14 修订：不再「先落库父件再补问」，也**不再弹窗**——确认超量后
    // 直接进入「跟父件一起办」整页（树表格 + 右下悬浮动作），此刻零网络写。
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    expect(find.text('下层还没下单，跟父件一起办'), findsOneWidget);
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );

    // 树顶是本次要下达的那个件本身（只读上下文，状态列说明），下面才是子层 /
    // 孙层；名称列用与准备页同款的树组件（缩进 + 连线 + 展开箭头）。
    expect(find.textContaining('本次将下达 20'), findsOneWidget);
    expect(_inDialog('成品A'), findsOneWidget);
    expect(_inDialog('外购件B'), findsOneWidget);
    expect(_inDialog('半成品C'), findsOneWidget);
    expect(_inDialog('外购件D'), findsOneWidget);
    // 收起「半成品C」分支：孙层外购件D 隐藏（勾选随之撤掉），再展开原样回来
    // ——展开不自动恢复勾选（所见勾选=提交内容），补勾 D 后整批照常提交。
    await tester.tap(find.byKey(const Key('cascade-toggle-m-c')));
    await tester.pumpAndSettle();
    expect(_inDialog('外购件D'), findsNothing);
    await tester.tap(find.byKey(const Key('cascade-toggle-m-c')));
    await tester.pumpAndSettle();
    expect(_inDialog('外购件D'), findsOneWidget);
    await _tapRowCheckbox(tester, '外购件D');

    // 数量按本批 20 算：B=20×2=40、C=20×1=20、D=20×3=60。
    expect(_qtyOf(tester, 'm-b'), '40');
    expect(_qtyOf(tester, 'm-c'), '20');
    expect(_qtyOf(tester, 'm-d'), '60');

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 一键下单之后才有提交：父件 issue-plans → 采购 notify → 下层自制 issue-plans。
    final issue = harness.writes
        .where((request) => request.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(2));
    // 第一次是父件产品行（本批 20），第二次是下层办齐把半成品C下到车间（20）。
    final parentLines =
        (issue.first.data as Map<String, dynamic>)['lines'] as List;
    expect(
      (parentLines.single as Map<String, dynamic>)['analysisLineId'],
      'p1',
    );
    final cascadeLines =
        (issue.last.data as Map<String, dynamic>)['lines'] as List;
    expect(cascadeLines, hasLength(1));
    final line = cascadeLines.single as Map<String, dynamic>;
    expect(line['materialLineId'], 'm-c');
    expect(line['qty'], 20.0);
    expect(line['departmentId'], 'dept-1');

    // 采购两行合并成一次 notify。
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    final notifyBody = notify.single.data as Map<String, dynamic>;
    expect(notifyBody['target'], 'BUY');
    // 超出本需求的部分按 V472 分账：qty = 归本需求量，publicExtraQty = 公共备货量。
    expect(
      (notifyBody['quantities'] as List)
          .cast<Map<String, dynamic>>()
          .map(
            (row) =>
                '${row['actionGroupKey']}=${row['qty']}+${row['publicExtraQty']}',
          )
          .toSet(),
      {'ag-b=20.0+20.0', 'ag-d=30.0+30.0'},
    );
  });

  testWidgets('已下单子件：申请未分解并入原申请调量，已分解问过后按追加另立', (tester) async {
    final harness = await _pump(tester, childrenAlreadyOrdered: true);

    await _openWorkshopBucket(tester);

    // 基础需求已全部下过单（现货全覆盖=还可下达 0），按 20 超量下达 →
    // 下层超产多需：B=20、C=10、D=60。
    await tester.enterText(_bucketQty('p1'), '20');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(find.textContaining('创建生产计划('));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认超量下达'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    // 联动状态加载后：B（申请未分解）显示并入口径，D（已分解）显示追加口径。
    await tester.pumpAndSettle();
    expect(find.textContaining('PR-0001（未分解）'), findsOneWidget);
    expect(find.textContaining('已下单 PO-0002'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    // 确认弹窗把两类去向说清（用户口径「问是不是追加」）。
    final confirmDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
        of: confirmDialog,
        matching: find.textContaining('并入原申请'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: confirmDialog,
        matching: find.textContaining('按「追加」另立申请'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 并入申请：把 PR-0001 明细从 20 改大到 20+20=40（V477 sanctioned 入口）。
    final adjust = harness.writes
        .where((request) => request.path.endsWith('/items/pri-1/qty'))
        .toList();
    expect(adjust, hasLength(1));
    expect(adjust.single.data, {'qty': 40.0});

    // 已分解的 D 不再走普通下单通道，而是 notify 超量通道的追加申请：
    // 基础需求 30 已下过单（余量 0），本批毛需求 60 → 追加 30 全进公共备货。
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    final quantities =
        (notify.single.data as Map<String, dynamic>)['quantities'] as List;
    expect(
      quantities
          .cast<Map<String, dynamic>>()
          .map(
            (row) =>
                '${row['actionGroupKey']}=${row['qty']}+${row['publicExtraQty']}',
          )
          .toSet(),
      {'ag-d=0.0+30.0'},
    );

    // 半成品C 是自制候选：照常走 issue-plans（父件 + 下层各一次）。
    final issue = harness.writes
        .where((request) => request.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(2));
    final cascadeLines =
        (issue.last.data as Map<String, dynamic>)['lines'] as List;
    expect(
      (cascadeLines.single as Map<String, dynamic>)['materialLineId'],
      'm-c',
    );
  });

  testWidgets('分桶详情改供应方式=立即确认路线并换桶', (tester) async {
    final harness = await _pump(tester);
    final entry = find.byKey(const Key('material-analysis-entry-buy'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 采购桶里把「外购件B」的供应方式改成自制。
    await tester.tap(
      find.byKey(const ValueKey('material-bucket-route-NODE|ag-b|m-b')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自制').last);
    await tester.pumpAndSettle();
    expect(find.text('确认并换桶'), findsOneWidget);
    await tester.tap(find.text('确认并换桶'));
    await tester.pumpAndSettle();

    final routes = harness.writes
        .where((request) => request.path.endsWith('/routes'))
        .toList();
    expect(routes, hasLength(1));
    expect((routes.single.data as Map<String, dynamic>)['decisions'], [
      {'actionGroupKey': 'ag-b', 'route': 'MAKE'},
    ]);
  });

  testWidgets('下层无需再下单时不弹弹窗，父件直接按原路提交', (tester) async {
    await _pump(tester, childrenAlreadyOrdered: true);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '10');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(find.textContaining('创建生产计划('));
    await tester.pumpAndSettle();
    await tester.tap(find.text('留在物料分析'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsNothing,
    );
  });
}

Finder _inDialog(String text) => find.descendant(
  of: find.byKey(const Key('material-analysis-child-cascade-dialog')),
  matching: find.text(text),
);

Finder _bucketQty(String rowId) =>
    find.byKey(ValueKey('material-analysis-bucket-qty-$rowId'));

/// 按行内文本定位整行（横滚时首列勾选框在冻结包裹层里，不再是数据 Row 的后代）
/// 并点它的勾选框。
Future<void> _tapRowCheckbox(WidgetTester tester, String text) async {
  final frozen = find.ancestor(
    of: find.text(text).first,
    matching: find.byType(UtenFrozenLeadingColumn),
  );
  final row = frozen.evaluate().isNotEmpty
      ? frozen.first
      : find
            .ancestor(of: find.text(text).first, matching: find.byType(Row))
            .first;
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

String _qtyOf(WidgetTester tester, String materialLineId) => tester
    .widget<TextField>(
      find.byKey(
        ValueKey('material-analysis-child-cascade-qty-$materialLineId'),
      ),
    )
    .controller!
    .text;

Future<void> _openWorkshopBucket(WidgetTester tester) async {
  final entry = find.byKey(const Key('material-analysis-entry-workshop'));
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

class _Harness {
  final List<RequestOptions> writes = [];
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool childrenAlreadyOrdered = false,
}) async {
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.method != 'GET') harness.writes.add(request);
        final analysis = _analysis(
          childrenAlreadyOrdered: childrenAlreadyOrdered,
        );
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
          ],
          '/production/material-analyses/default-workshops' => [
            for (final goods in ['g-a', 'g-c'])
              {
                'goodsId': goods,
                'departmentId': 'dept-1',
                'departmentName': '一车间',
                'responsibleEmployeeId': 'emp-1',
                'responsibleEmployeeName': '张三',
              },
          ],
          '/production/material-analyses/sales-candidates' => {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          // 已下单子件的下游联动（ADR-081）：B=申请未分解可并入，D=已分解按追加。
          '/production/material-analyses/analysis-1/supply-links' => [
            {
              'materialLineId': 'm-b',
              'route': 'BUY',
              'mode': 'ADJUSTABLE',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'pr-1',
              'documentNo': 'PR-0001',
              'documentItemId': 'pri-1',
              'itemQty': 20,
              'orderedQty': 0,
            },
            {
              'materialLineId': 'm-d',
              'route': 'BUY',
              'mode': 'ORDERED',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'po-2',
              'documentNo': 'PO-0002',
              'documentItemId': 'poi-2',
              'itemQty': 30,
              'orderedQty': 30,
            },
          ],
          // 并入申请调量（V477）：返回最小合法详情即可。
          '/purchase/requests/pr-1/items/pri-1/qty' => {'id': 'pr-1'},
          '/production/material-analyses/analysis-1' => analysis,
          '/production/material-analyses/analysis-1/notify' => analysis,
          '/production/material-analyses/analysis-1/issue-plans' => {
            'analysis': analysis,
            'plans': [
              {'planId': 'plan-1', 'planNo': 'PP-1', 'status': 'DRAFT'},
            ],
          },
          _ => <Object>[],
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        purchaseRepositoryProvider.overrideWith(
          (ref, type) => PurchaseRepository(api, type),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(_DepartmentRepository()),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionMaterialAnalysisOverSupply,
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis-1',
            warehouseId: 'warehouse-1',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  harness.writes.clear();
  return harness;
}

class _DepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value.normalized();
  }
}

Map<String, dynamic> _analysis({required bool childrenAlreadyOrdered}) => {
  'analysisId': 'analysis-1',
  'status': 'ACTIVE',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'GENERATE_PLAN',
    'OVER_SUPPLY',
  ],
  'products': [
    {
      'analysisLineId': 'p1',
      'sourceType': 'STOCK',
      'rootMaterialLineId': 'root-1',
      // 销售订单来源顶层行：2026-09-14 修订二起超量也放行（服务端拆
      // 「订单行 + 公共备货单」两张计划），这里锁住前端不再拦。
      'salesOrderItemId': 'soi-1',
      'salesOrderNo': 'SO-0001',
      'goodsId': 'g-a',
      'goodsCode': 'A-001',
      'goodsName': '成品A',
      'unitName': '件',
      'requestedQty': 10,
      'remainingQty': 10,
      'readyNowQty': 0,
      'canSchedule': true,
      'maxSchedulableQty': 10,
    },
  ],
  'flatMaterials': [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
      covered: childrenAlreadyOrdered,
    ),
    _material(
      id: 'm-c',
      name: '半成品C',
      goodsId: 'g-c',
      level: 1,
      nodeKey: 'nc',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      actionGroupKey: 'ag-c',
      covered: childrenAlreadyOrdered,
    ),
    _material(
      id: 'm-d',
      name: '外购件D',
      goodsId: 'g-d',
      level: 2,
      nodeKey: 'nc/nd',
      parentNodeKey: 'nc',
      perProductQty: 3,
      requiredQty: 30,
      route: 'BUY',
      actionGroupKey: 'ag-d',
      covered: childrenAlreadyOrdered,
    ),
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _material({
  required String id,
  required String name,
  required String goodsId,
  required int level,
  required String nodeKey,
  required double perProductQty,
  required double requiredQty,
  required String route,
  required String actionGroupKey,
  String? parentNodeKey,
  String nodeRole = 'BOM_COMPONENT',
  bool covered = false,
}) => {
  'materialLineId': id,
  'analysisLineId': 'p1',
  'nodeRole': nodeRole,
  'nodeKey': nodeKey,
  'parentNodeKey': parentNodeKey,
  'goodsId': goodsId,
  'goodsCode': '$goodsId-code',
  'goodsName': name,
  'unitName': '件',
  'level': level,
  'actionable': level > 0,
  'actionGroupKey': actionGroupKey,
  'materialKey': goodsId,
  'perProductQty': perProductQty,
  'requiredQty': requiredQty,
  // covered=true 时现货已全覆盖：还可下达 = 0，不该再进下层办齐弹窗。
  'availableQty': covered ? requiredQty : 0,
  'allocatedAvailableQty': covered ? requiredQty : 0,
  'shortageQty': covered ? 0 : requiredQty,
  'demandSupplyGapQty': covered ? 0 : requiredQty,
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'warehouseBreakdown': <Object>[],
};
