// 车间生产任务页的车间内料仓用料状态 (ADR-131 §5.4、§5.5) widget 测试。
//
// 覆盖: 待认料显示「待认料」并在等待物料里; 待认料的行 (needsStartConfirmation)
// 可勾选、点开工弹出开工确认表, 办完回来刷新并提示; 路线未确认的行同样弹表;
// 内料仓未开启的行红字、不能勾选; 行菜单「这张工单改用别的料」只在段级动作
// 含 CHANGE_MATERIAL 时出现, 换料成功后刷新并提示。
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/production/models/production_flow_stage.dart';
import 'package:uten_imp/features/production/widgets/production_flow_stage_cell.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/repositories/production_material_discovery_request_repository.dart';
import 'package:uten_imp/features/production/repositories/production_material_increment_repository.dart';
import 'package:uten_imp/features/production/repositories/workshop_material_choice_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../support/filter_segment_tap.dart';

Map<String, dynamic> _task(
  String id,
  String product,
  String status, {
  String? startRoute = 'FULL_KIT',
  String? binState,
  bool needsStartConfirmation = false,
  bool canStart = false,
  bool canConfirmRoute = false,
  bool discoveryRequired = false,
  bool canRequestDiscovery = false,
  bool canRequestDraw = false,
  bool canSplitBatch = false,
  bool zeroMaterial = true,
  List<String> allowedActions = const [],
}) => {
  'segmentId': id,
  'planId': 'plan-$id',
  'planNo': 'SJ-$id',
  'segmentCode': 'GD-$id',
  'salesOrderNos': 'SO-001',
  'workshopDepartmentId': 'workshop-1',
  'workshopName': '注塑车间',
  'responsibleEmployeeName': '负责人',
  'productCode': 'P-$id',
  'productName': product,
  'productColorName': '本色',
  'productUnitName': '件',
  'plannedQty': 10,
  'reportedQty': status == 'IN_PROGRESS' ? 2 : 0,
  'remainingReportQty': status == 'IN_PROGRESS' ? 8 : 10,
  'segmentStatus': status,
  'materialStatus': 'KIT_READY',
  'preparationStatus': 'PREPARED',
  'materialReady': true,
  'warehouseReady': true,
  'issued': true,
  'zeroMaterial': zeroMaterial,
  'materialKindCount': zeroMaterial ? 0 : 1,
  'canStart': canStart,
  'canReport': status == 'IN_PROGRESS',
  'canBatchReport': status == 'IN_PROGRESS',
  'lockVersion': 1,
  'startRoute': startRoute,
  'canConfirmRoute': canConfirmRoute,
  'materialDiscoveryRequired': discoveryRequired,
  'canRequestMaterialDiscovery': canRequestDiscovery,
  'canRequestDraw': canRequestDraw,
  'canSplitBatch': canSplitBatch,
  'binMaterialState': ?binState,
  'needsStartConfirmation': needsStartConfirmation,
  'allowedActions': allowedActions,
};

final _waitingRows = [
  _task(
    'segment-a',
    '产品 A',
    'READY',
    binState: 'NEED_CHOICE',
    needsStartConfirmation: true,
    discoveryRequired: true,
    canRequestDiscovery: true,
    allowedActions: const ['CHOOSE'],
  ),
  _task(
    'segment-n',
    '产品 N',
    'READY',
    binState: 'NEED_BIN',
    discoveryRequired: true,
    canRequestDiscovery: true,
  ),
  _task(
    'segment-r',
    '产品 R',
    'READY',
    startRoute: null,
    binState: 'NO_BIN',
    needsStartConfirmation: true,
    canConfirmRoute: true,
  ),
];

final _inProgressRows = [
  _task(
    'segment-b',
    '产品 B',
    'IN_PROGRESS',
    binState: 'KNOWN',
    allowedActions: const ['CHANGE_MATERIAL'],
  ),
  _task('segment-c', '产品 C', 'IN_PROGRESS', binState: 'KNOWN'),
];

ProductionExecutionWorkbenchRepository _repository({
  List<Map<String, dynamic>>? preparingRows,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final Object data;
        if (request.path == '/production/workshop-tasks') {
          final items = request.queryParameters['status'] == 'IN_PROGRESS'
              ? _inProgressRows
              : preparingRows ?? _waitingRows;
          data = {
            'items': items,
            'page': 1,
            'size': 50,
            'total': items.length,
            'totalPages': 1,
          };
        } else if (request.path.endsWith('/materials')) {
          data = const <Object>[];
        } else {
          data = <String, dynamic>{};
        }
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
  return ProductionExecutionWorkbenchRepository(ApiClient(dio));
}

class _FakeChoiceRepository extends WorkshopMaterialChoiceRepository {
  _FakeChoiceRepository(this.calls) : super(ApiClient(Dio()));

  final List<String> calls;
  final List<({String segmentId, int expectedVersion, String? fromRowId})>
  changes = [];
  String? changedEffectiveFrom;
  String? changedWeightBasis;
  WorkshopMaterialRef? changedTo;

  @override
  Future<List<WorkshopMaterialPendingChoice>> pending(
    List<String> segmentIds,
  ) async => [
    if (segmentIds.contains('segment-a'))
      const WorkshopMaterialPendingChoice(
        workshopDepartmentId: 'workshop-1',
        productGoodsId: 'goods-a',
        productName: '产品 A',
        segmentIds: ['segment-a'],
        taskCount: 1,
        choiceRequired: true,
        prefill: [WorkshopMaterialRef(goodsId: 'pp')],
        options: [
          WorkshopMaterialOption(
            goodsId: 'pp',
            goodsName: 'PP',
            colorName: '黑',
          ),
        ],
        alsoOrderMaterialsAllowed: true,
      ),
    if (segmentIds.contains('segment-r'))
      const WorkshopMaterialPendingChoice(
        workshopDepartmentId: 'workshop-1',
        productGoodsId: 'goods-r',
        productName: '产品 R',
        segmentIds: ['segment-r'],
        taskCount: 1,
        choiceRequired: false,
      ),
  ];

  @override
  Future<void> choose({
    required String workshopDepartmentId,
    required List<WorkshopMaterialProductChoice> choices,
    required String idempotencyKey,
  }) async {
    calls.add('choose');
  }

  @override
  Future<WorkshopMaterialSegmentMaterials> segmentMaterials(
    String segmentId,
  ) async => const WorkshopMaterialSegmentMaterials(
    rows: [
      WorkshopMaterialSegmentRow(
        id: 'row-pp',
        materialGoodsId: 'pp',
        materialName: 'PP',
        materialColorName: '黑',
        effectiveFrom: '2026-09-01',
        unitWeightGrams: 12,
      ),
    ],
    options: [
      WorkshopMaterialOption(goodsId: 'pp', goodsName: 'PP', colorName: '黑'),
      WorkshopMaterialOption(goodsId: 'abs', goodsName: 'ABS', colorName: '白'),
    ],
    lockVersion: 7,
  );

  @override
  Future<List<WorkshopMaterialSegmentRow>> changeMaterial(
    String segmentId, {
    required int expectedVersion,
    String? fromRowId,
    required WorkshopMaterialRef to,
    required String effectiveFrom,
    required String weightBasis,
    String? reason,
    required String idempotencyKey,
  }) async {
    calls.add('change:$segmentId');
    changes.add((
      segmentId: segmentId,
      expectedVersion: expectedVersion,
      fromRowId: fromRowId,
    ));
    changedTo = to;
    changedEffectiveFrom = effectiveFrom;
    changedWeightBasis = weightBasis;
    return const [];
  }
}

class _FakePlanRepository extends ProductionPlanRepository {
  _FakePlanRepository(this.calls)
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))));

  final List<String> calls;

  @override
  Future<ProductionExecutionSegmentView> confirmExecutionSegmentRoute(
    String planId,
    String segmentId, {
    required int expectedVersion,
    required String route,
  }) async {
    calls.add('route:$segmentId:$route');
    return ProductionExecutionSegmentView.fromJson({
      'id': segmentId,
      'packageId': 'package',
      'planId': planId,
      'sourcePlanItemId': 'plan-item',
      'segmentCode': 'SEG-1',
      'productGoodsId': 'goods',
      'plannedQty': 10,
      'reportedQty': 0,
      'remainingQty': 10,
      'lockVersion': expectedVersion + 1,
      'status': 'READY',
    });
  }

  @override
  Future<void> batchStartExecutionSegments(
    String planId, {
    required List<({String segmentId, int expectedVersion})> items,
  }) async {
    calls.add('start:$planId');
  }
}

class _FakeDiscoveryRepository
    extends ProductionMaterialDiscoveryRequestRepository {
  _FakeDiscoveryRepository(this.calls) : super(ApiClient(Dio()));

  final List<String> calls;

  @override
  Future<void> cancel(String requestId) async {
    calls.add('cancel:$requestId');
  }
}

GoRouter _router() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const ProductionWorkshopTasksPage()),
    GoRoute(
      path: '/production/workshop-tasks/draw-request',
      builder: (_, state) => Scaffold(
        body: Text('领料汇总 ${state.uri.queryParameters['segmentIds']}'),
      ),
    ),
    GoRoute(
      path: '/production/material-discovery-request',
      builder: (_, state) => Scaffold(
        body: Text('按单领料申请 ${state.uri.queryParameters['segmentIds']}'),
      ),
    ),
    GoRoute(
      path: '/workshop-material/bin',
      builder: (_, state) => Scaffold(
        body: Text('内料仓 ${state.uri.queryParameters['workshopId']}'),
      ),
    ),
  ],
);

Future<List<String>> _mount(
  WidgetTester tester, {
  String category = '开工准备',
  List<Map<String, dynamic>>? preparingRows,
  Set<String> extraPermissions = const {},
}) async {
  // 用 view 尺寸 (而不是 setSurfaceSize): 侧板宽度按 MediaQuery 算, 两者要一致。
  tester.view
    ..physicalSize = const Size(1800, 1100)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = _router();
  addTearDown(router.dispose);
  final calls = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionExecutionView,
          Perm.productionExecutionStart,
          ...extraPermissions,
        }),
        productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
          _repository(preparingRows: preparingRows),
        ),
        productionPlanRepositoryProvider.overrideWithValue(
          _FakePlanRepository(calls),
        ),
        workshopMaterialChoiceRepositoryProvider.overrideWithValue(
          _FakeChoiceRepository(calls),
        ),
        productionMaterialDiscoveryRequestRepositoryProvider.overrideWithValue(
          _FakeDiscoveryRepository(calls),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await selectFilterSegment(tester, category);
  await tester.pumpAndSettle();
  return calls;
}

/// 行首勾选格被冻结成整行 Stack 的 Positioned 兄弟 (UtenFrozenLeadingColumn)。
Finder _frozenRowOf(String text) {
  final frozen = find.ancestor(
    of: find.text(text).first,
    matching: find.byType(UtenFrozenLeadingColumn),
  );
  if (frozen.evaluate().isNotEmpty) return frozen.first;
  return find
      .ancestor(of: find.text(text).first, matching: find.byType(Row))
      .first;
}

Future<void> _selectRow(WidgetTester tester, String product) async {
  final checkbox = find
      .descendant(of: _frozenRowOf(product), matching: find.byType(Checkbox))
      .first;
  await tester.tap(checkbox);
  await tester.pump();
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

final Finder _menuSurface = find.byWidgetPredicate(
  (widget) => widget is Material && widget.elevation == 8,
  description: 'UtenContextMenu surface',
);

Finder _menuEntry(String label) =>
    find.descendant(of: _menuSurface, matching: find.text(label));

/// 2026-09-27 去胶囊口径：状态语义由整格底色承载——取该文本所在格的
/// 第一个带背景色的 BoxDecoration（即 cellColor 铺的底）。
Color _cellBackgroundColor(WidgetTester tester, String label) {
  final start = tester.element(find.text(label).first);
  Color? found;
  start.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Container) {
      final decoration = widget.decoration;
      if (decoration is BoxDecoration && decoration.color != null) {
        found = decoration.color!;
        return false;
      }
    }
    return true;
  });
  return found!;
}

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets('a task waiting for a material choice shows 待认料 in waiting', (
    tester,
  ) async {
    await _mount(tester);
    expect(find.text('待认料'), findsWidgets);
    // 等待物料段整格铺实底（decide=红：车间必须先决定，其它动作全锁着）。
    expect(
      _cellBackgroundColor(tester, '待认料'),
      productionReadinessCellColor(ProductionFlowTone.decide),
    );
    expect(find.text('待认料 · 开工时选用料'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a store that is not enabled shows red and cannot be ticked', (
    tester,
  ) async {
    await _mount(tester);
    expect(find.text('车间内料仓未开启 · 不能开工'), findsWidgets);
    expect(
      _cellBackgroundColor(tester, '车间内料仓未开启 · 不能开工'),
      productionReadinessCellColor(ProductionFlowTone.decide),
    );
    expect(
      find.descendant(
        of: _frozenRowOf('产品 N'),
        matching: find.byType(Checkbox),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a task waiting for a choice can be ticked; start opens the '
      'confirmation sheet and the page refreshes afterwards', (tester) async {
    final calls = await _mount(tester);
    await _selectRow(tester, '产品 A');
    expect(find.text('批量开工(1)'), findsOneWidget);
    expect(find.text('批量领料(0)'), findsOneWidget);
    await tester.tap(find.text('批量开工(1)'));
    await tester.pumpAndSettle();

    expect(find.text('开工前确认用料'), findsOneWidget);
    expect(find.text('按上次选的料预填，请核对'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();

    expect(calls, ['choose', 'start:plan-segment-a']);
    expect(find.text('开工前确认用料'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionWorkshopTasksPage)),
    );
    expect(
      container.read(appNotificationProvider).last.message,
      contains('已开工 1 个工单'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('choice state opens confirmation instead of the old discovery '
      'entry even when both server discovery flags are true', (tester) async {
    await _mount(tester);
    expect(
      find.byKey(const ValueKey('workshop-request-draw-segment-a')),
      findsNothing,
    );
    await _rightClick(tester, find.text('产品 A').first);
    expect(_menuEntry('去领料(查看领料汇总)'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('workshop-confirm-material-segment-a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('开工前确认用料'), findsOneWidget);
    expect(find.textContaining('按单领料申请'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed selection sends only order materials to discovery', (
    tester,
  ) async {
    await _mount(
      tester,
      preparingRows: [
        _waitingRows.first,
        _task(
          'segment-order',
          '按单产品',
          'READY',
          binState: 'ORDER_ONLY',
          discoveryRequired: true,
          canRequestDiscovery: true,
        ),
        _task(
          'segment-insert',
          '嵌件产品',
          'READY',
          binState: 'KNOWN',
          discoveryRequired: true,
          canRequestDiscovery: true,
        ),
      ],
    );
    await _selectRow(tester, '产品 A');
    await _selectRow(tester, '按单产品');
    await _selectRow(tester, '嵌件产品');
    expect(find.text('批量开工(1)'), findsOneWidget);
    expect(find.text('批量领料(2)'), findsOneWidget);
    await tester.tap(find.text('批量领料(2)'));
    await tester.pumpAndSettle();
    final destination = find.textContaining('按单领料申请 ');
    expect(destination, findsOneWidget);
    expect(
      tester
          .widget<Text>(destination)
          .data!
          .substring('按单领料申请 '.length)
          .split(','),
      unorderedEquals(['segment-order', 'segment-insert']),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unconfigured store never offers ordinary or batch issue', (
    tester,
  ) async {
    await _mount(
      tester,
      preparingRows: [
        _task(
          'segment-n',
          '产品 N',
          'READY',
          startRoute: 'BATCH',
          binState: 'NEED_BIN',
          canSplitBatch: true,
          discoveryRequired: true,
          canRequestDiscovery: true,
        ),
      ],
    );
    await _rightClick(tester, find.text('产品 N').first);
    expect(_menuEntry('去领料(查看领料汇总)'), findsNothing);
    expect(_menuEntry('分批生产领料'), findsNothing);
    expect(_menuEntry('为什么不能开工'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing CHOOSE cannot be bypassed through stale start or '
      'discovery flags', (tester) async {
    await _mount(
      tester,
      preparingRows: [
        _task(
          'segment-a',
          '产品 A',
          'READY',
          binState: 'NEED_CHOICE',
          canStart: true,
          needsStartConfirmation: true,
          discoveryRequired: true,
          canRequestDiscovery: true,
        ),
      ],
    );
    expect(
      find.descendant(
        of: _frozenRowOf('产品 A'),
        matching: find.byType(Checkbox),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('workshop-confirm-material-segment-a')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('workshop-request-draw-segment-a')),
      findsNothing,
    );
    await _rightClick(tester, find.text('产品 A').first);
    expect(_menuEntry('开工'), findsNothing);
    expect(_menuEntry('去领料(查看领料汇总)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pure bin materials hide order increment while mixed products '
      'keep it', (tester) async {
    await _mount(
      tester,
      extraPermissions: {productionMaterialIncrementPermission},
      preparingRows: [
        _task('segment-pure', '纯颗粒产品', 'READY', binState: 'KNOWN'),
        _task(
          'segment-mixed',
          '含嵌件产品',
          'READY',
          binState: 'KNOWN',
          zeroMaterial: false,
        ),
      ],
    );
    await _rightClick(tester, find.text('纯颗粒产品').first);
    expect(_menuEntry('申请追加用料'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await _rightClick(tester, find.text('含嵌件产品').first);
    expect(_menuEntry('申请追加用料'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recognized material can still cancel its old pending order '
      'discovery request', (tester) async {
    final calls = await _mount(
      tester,
      preparingRows: [
        _task('segment-pure', '已认料产品', 'READY', binState: 'KNOWN')..addAll({
          'materialDiscoveryStatus': 'PENDING',
          'materialDiscoveryRequestId': 'request-old',
        }),
      ],
    );
    await _rightClick(tester, find.text('已认料产品').first);
    expect(_menuEntry('撤回待登记领料申请'), findsOneWidget);
    await tester.tap(_menuEntry('撤回待登记领料申请'));
    await tester.pumpAndSettle();
    expect(calls, ['cancel:request-old']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('NO_BIN discovery explains bulk configuration and opens the '
      'matching workshop without suppressing order issue', (tester) async {
    await _mount(
      tester,
      extraPermissions: {Perm.workshopMaterialView},
      preparingRows: [
        _task(
          'segment-no-bin',
          '未配置产品',
          'READY',
          binState: 'NO_BIN',
          discoveryRequired: true,
          canRequestDiscovery: true,
        ),
      ],
    );
    await tester.tap(find.text('未配置产品').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('未配置产品').first);
    await tester.pumpAndSettle();
    expect(find.text('车间任务详情'), findsOneWidget);
    expect(find.textContaining('若原料会提前整批放在车间使用'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workshop-detail-draw-segment-no-bin')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('workshop-detail-material-bin-segment-no-bin')),
    );
    await tester.pumpAndSettle();
    expect(find.text('内料仓 workshop-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a task whose route is not confirmed also opens the sheet', (
    tester,
  ) async {
    final calls = await _mount(tester);
    await _selectRow(tester, '产品 R');
    expect(find.text('批量开工(1)'), findsOneWidget);
    await tester.tap(find.text('批量开工(1)'));
    await tester.pumpAndSettle();

    expect(find.text('开工前确认用料'), findsOneWidget);
    expect(find.text('用料已定'), findsWidgets);
    expect(find.text('确认并开工 (0)'), findsOneWidget, reason: '路线还没选');
    await tester.tap(find.byKey(const ValueKey('start-sheet-route-goods-r')));
    await tester.pumpAndSettle();
    await tester.tap(_menuEntry('持续生产'));
    await tester.pumpAndSettle();
    expect(find.text('确认并开工 (1)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();

    expect(calls, ['route:segment-r:CONTINUOUS', 'start:plan-segment-r']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('change material only shows when the server allows it', (
    tester,
  ) async {
    final calls = await _mount(tester, category: '生产中');
    // 产品 C 的段级动作里没有 CHANGE_MATERIAL: 菜单里没有这一条(本行别的
    // 条目也都不满足, 菜单根本不弹)。
    await _rightClick(tester, find.text('产品 C').first);
    expect(_menuEntry('这张工单改用别的料'), findsNothing);

    await _rightClick(tester, find.text('产品 B').first);
    expect(_menuEntry('这张工单改用别的料'), findsOneWidget);
    await tester.tap(_menuEntry('这张工单改用别的料'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('segment-material-change-from')),
      findsOneWidget,
    );
    expect(find.text('PP 黑 · 单个重量 12 克'), findsOneWidget);
    await tester.tap(find.byKey(const Key('segment-material-change-to')));
    await tester.pumpAndSettle();
    await tester.tap(_menuEntry('ABS 白'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('segment-material-change-submit')));
    await tester.pumpAndSettle();

    expect(calls, ['change:segment-b']);
    final choices =
        ProviderScope.containerOf(
              tester.element(find.byType(ProductionWorkshopTasksPage)),
            ).read(workshopMaterialChoiceRepositoryProvider)
            as _FakeChoiceRepository;
    expect(choices.changes.single.expectedVersion, 7);
    expect(choices.changes.single.fromRowId, 'row-pp');
    expect(choices.changedTo, const WorkshopMaterialRef(goodsId: 'abs'));
    expect(choices.changedWeightBasis, workshopMaterialWeightFromReplaced);
    expect(
      choices.changedEffectiveFrom,
      ChinaDateTime.formatDate(ChinaDateTime.today()),
    );
    expect(find.text('这张工单改用别的料'), findsNothing, reason: '对话框已关');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionWorkshopTasksPage)),
    );
    expect(
      container.read(appNotificationProvider).last.message,
      contains('已改用新料'),
    );
    expect(tester.takeException(), isNull);
  });
}
