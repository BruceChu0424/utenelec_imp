import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'each category and fullscreen have one table-owned selection action',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: true)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(
        const Key('subcontract-decomposition-create-order'),
      );
      for (final category in ['待处理', '等待财务审核', '财务已通过', '财务驳回', '历史记录']) {
        await tester.tap(find.text(category));
        await tester.pumpAndSettle();
        if (category == '历史记录') {
          expect(action, findsNothing);
          expect(find.byType(UtenSelectionSummaryPill), findsNothing);
          await tester.tap(find.text('全部'));
          await tester.pumpAndSettle();
        }
        expect(action, findsOneWidget, reason: category);
        expect(
          find.byType(UtenSelectionSummaryPill),
          findsOneWidget,
          reason: category,
        );
        expect(
          find.ancestor(
            of: action,
            matching: find.byType(MasterDataTableView<OperationsWorkbenchTask>),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('FG-task-1 委外目标件'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.text('全屏'));
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const Key('master-table-clear-selection')));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(tester.widget<UtenButton>(action).onPressed, isNull);
      await tester.tap(find.text('退出全屏'));
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(find.text('已选 0 项'), findsOneWidget);
      await tester.tap(find.text('FG-task-1 委外目标件'));
      await tester.pumpAndSettle();
      for (final width in [900.0, 375.0, 1400.0]) {
        tester.view.physicalSize = Size(width, 1400);
        await tester.pumpAndSettle();
        expect(action, findsOneWidget, reason: 'width=$width');
        expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
        expect(find.text('已选 1 项'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(375, 1400);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenSelectionSummaryPill),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(tester.widget<UtenButton>(action).onPressed, isNull);
      await tester.ensureVisible(find.text('历史记录'));
      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      expect(action, findsNothing);
      expect(find.byType(UtenSelectionSummaryPill), findsNothing);
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact decomposition selects issued application lines and enables one primary action',
    (tester) async {
      final gateway = _Gateway(_data(capability: true));
      tester.view.physicalSize = const Size(375, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('subcontract-decomposition-compact-list')),
        findsOneWidget,
      );
      // 进页面只拉一次 size=1 概览（阶段计数徽章），不带 status 过滤。
      expect(gateway.statuses, [null]);
      // 2026-09-03 分类范式：阶段行默认不选（引导占位，不发列表请求），
      // 原「概览卡 + 阶段/异常下拉」已删除。
      expect(find.text('在上方选择阶段后开始办理'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      // 2026-09-06 委外不再有「分解」行为用语：首段改名「待处理」。
      expect(find.text('待处理'), findsOneWidget);
      var button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNull);

      // 先 tap 阶段段「待处理」：加载任务卡后才能勾选。
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      expect(gateway.statuses, [null, 'WAITING_ORDER']);
      expect(find.text('计划申请已下达 / 待分解'), findsNWidgets(2));

      await tester.tap(find.byType(Checkbox).at(0));
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      await tester.pumpAndSettle();

      button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.text('生成委外订货单(2)'), findsOneWidget);
      // 2026-09-06 顶部选中摘要条退役：已选计数走右下角悬浮组标准胶囊。
      expect(
        find.byKey(const Key('subcontract-decomposition-selection')),
        findsNothing,
      );
      expect(find.text('已选 2 项'), findsOneWidget);
    },
  );

  testWidgets(
    'waiting-production tasks merge into 待处理 with progress dialog on double-click',
    (tester) async {
      // 2026-09-06 计划委外申请页并入任务中心：待生产合成行进「待处理」段，
      // 阶段列显示车间进度；合成行不可勾选；双击先看「产品进度」弹窗。
      final gateway = _Gateway(
        _data(capability: true, includePreparation: true),
      );
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();

      // 合成行（IN_PROGRESS→正在生产中；NOTIFYING_WORKSHOP→正在等待安排生产）；
      // FULLY_NOTIFIED 不合成（其申请单已由服务端生成）。
      expect(find.textContaining('委外件A'), findsOneWidget);
      expect(find.textContaining('委外件B'), findsOneWidget);
      expect(find.textContaining('委外件C'), findsNothing);
      expect(find.text('正在生产中'), findsOneWidget);
      expect(find.text('正在等待安排生产'), findsOneWidget);
      // 真实申请行与合成行同表。
      expect(find.text('EA-application-1'), findsWidgets);

      // 双击合成行（第一行是 task-a 合成行）→ 产品进度弹窗（车间进度时间线）。
      await _doubleTapRow(tester, find.textContaining('SC-A 委外件A'));
      await tester.pumpAndSettle();
      expect(find.textContaining('产品进度 ·'), findsOneWidget);
      expect(find.text('已通知委外·生成申请'), findsOneWidget);
      expect(find.text('生产中（当前）'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      // 双击申请行 → 全链路进度弹窗，可再深链只读申请。
      await _doubleTapRow(tester, find.text('FG-task-1 委外目标件'));
      await tester.pumpAndSettle();
      expect(find.text('待生成委外订货单（当前）'), findsOneWidget);
      expect(find.text('查看申请单'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in const [
    (
      name: 'missing local decompose permission',
      permissions: <String>{},
      capability: true,
    ),
    (
      name: 'server capability denies create',
      permissions: <String>{
        Perm.subcontractApplicationView,
        Perm.subcontractOrderView,
        Perm.subcontractOrderCreate,
        Perm.subcontractOrderDecompose,
      },
      capability: false,
    ),
  ]) {
    testWidgets('${scenario.name} hides selection and keeps action disabled', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(scenario.permissions),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: scenario.capability)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsNothing);
      final action = find.byKey(
        const Key('subcontract-decomposition-create-order'),
      );
      if (scenario.permissions.isEmpty) {
        expect(action, findsNothing);
      } else {
        expect(action, findsOneWidget);
        expect(tester.widget<UtenButton>(action).onPressed, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }
}

/// 双击指定行（两次点按间隔 50ms，落在 350ms 手动双击判定窗内）。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

/// 待生产委外任务桩（合成行数据源；其余请求回空）。
ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final dynamic data;
        if (request.path.contains('/subcontract-make-tasks/')) {
          final id = request.path.split('/').last;
          data = {
            'taskId': id,
            'analysisId': id == 'task-a' ? 'analysis-1' : 'analysis-2',
            'status': 'ACTIVE',
            'goodsCode': id == 'task-a' ? 'SC-A' : 'SC-B',
            'goodsName': id == 'task-a' ? '委外件A' : '委外件B',
            'workshopStatus': id == 'task-a'
                ? 'IN_PRODUCTION'
                : 'NOTIFYING_WORKSHOP',
          };
        } else {
          data = <dynamic>[];
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
  return ApiClient(dio);
}

class _Gateway implements OperationsWorkbenchGateway {
  _Gateway(this.data);
  final OperationsWorkbenchData data;
  final List<String?> statuses = <String?>[];

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
  }) async {
    statuses.add(status);
    return data;
  }
}

OperationsWorkbenchData _data({
  required bool capability,
  bool includePreparation = false,
}) => OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.subcontract,
  summary: OperationsWorkbenchSummary(
    totalTasks: includePreparation ? 4 : 2,
    overdueTasks: 0,
    openTasks: 2,
    openQty: 12,
    statusCounts: {'WAITING_ORDER': includePreparation ? 4 : 2},
  ),
  items: [
    if (includePreparation) ...[
      _preparationRow('task-a', 'SC-A', '委外件A', 'IN_PRODUCTION'),
      _preparationRow('task-b', 'SC-B', '委外件B', 'NOTIFYING_WORKSHOP'),
    ],
    _task('task-1', 'application-1', 'application-item-1'),
    _task('task-2', 'application-2', 'application-item-2'),
  ],
  page: 1,
  size: 20,
  total: includePreparation ? 4 : 2,
  totalPages: 1,
  capabilities: OperationsWorkbenchCapabilities(
    canCreateSubcontractOrder: capability,
  ),
);

OperationsWorkbenchTask _task(
  String taskId,
  String applicationId,
  String applicationItemId,
) => OperationsWorkbenchTask(
  taskId: taskId,
  packageId: 'package-1',
  planId: 'plan-1',
  planNo: 'PP-001',
  warehouseName: '委外目标仓',
  goodsCode: 'FG-$taskId',
  goodsName: '委外目标件',
  spec: '标准',
  colorName: '本色',
  unitName: '件',
  supplyRoute: 'SUBCONTRACT',
  requiredQty: 10,
  allocatedQty: 0,
  fulfilledQty: 0,
  supplyPeggedQty: 0,
  openQty: 6,
  taskStatus: 'WAITING_ORDER',
  needDate: '2026-09-10',
  expectedDate: null,
  exceptionCode: null,
  updatedAt: '2026-08-30T10:00:00Z',
  actionDocument: OperationsActionDocument(
    id: applicationId,
    docType: 'SUBCONTRACT_APPLICATION',
    number: 'EA-$applicationId',
    path: '/subcontract/applications/$applicationId',
    canView: true,
    canEdit: false,
    status: '1',
  ),
  actionDocItemId: applicationItemId,
  actionDocumentRestricted: false,
);

OperationsWorkbenchTask _preparationRow(
  String id,
  String code,
  String name,
  String stage,
) => OperationsWorkbenchTask.fromJson({
  'taskId': id,
  'supplyRoute': 'SUBCONTRACT',
  'taskStatus': 'WAITING_ORDER',
  'goodsCode': code,
  'goodsName': name,
  'requiredQty': 10,
  'openQty': 10,
  'actionDocType': 'SUBCONTRACT_MAKE_TASK',
  'actionDocId': id,
  'actionDocCanView': true,
  'actionDocCanEdit': false,
  'actionDocStatus': stage,
}, OperationsWorkbenchDepartment.subcontract);
