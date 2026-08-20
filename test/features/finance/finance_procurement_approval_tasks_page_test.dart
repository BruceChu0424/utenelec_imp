// 财务订货审批任务中心「页内审批」回归测试。
//
// 背景：审批按钮原先长在采购/委外订货详情页——admin 等同时持财务审核资格的
// 账号在采购模块提交订货后立刻看到「财务通过」按钮，被业务方质疑流程越位。
// 收敛后：订货详情页只读展示等待状态；审批的权威操作位在财务专属的任务中心
// 卡片上（通过 / 退回修改），allowedActions 由服务端按 V229 资格放行。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_tasks_page.dart';
import 'package:uten_imp/features/finance/providers/finance_procurement_approval_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// 记录型假仓库：只回固定的一页任务，并记录页内审批调用。
class _FakeWorkflowRepo implements FinanceProcurementWorkflowRepository {
  _FakeWorkflowRepo(this.items);

  final List<FinanceProcurementApprovalTask> items;
  final List<String> approvedOrderIds = [];

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
  }) async => FinanceProcurementApprovalPage(
    items: items,
    page: 1,
    size: 20,
    total: items.length,
    totalPages: 1,
  );

  @override
  Future<int> pendingApprovalCount() async => items.length;

  @override
  Future<Map<String, int>> approvalTypeCounts() async => const {'PURCHASE': 1};

  @override
  Future<void> approveOrder(
    FinanceProcurementOrderType orderType,
    String orderId,
    int expectedVersion,
  ) async {
    approvedOrderIds.add('$orderType|$orderId|v$expectedVersion');
  }

  @override
  Future<void> rejectOrder(
    FinanceProcurementOrderType orderType,
    String orderId,
    int expectedVersion,
    String reason,
  ) async {}
}

Map<String, dynamic> _purchaseTaskJson() => <String, dynamic>{
  'caseId': 'case-1',
  'orderId': 'order-1',
  'orderType': 'PURCHASE',
  'billNo': 'PO-2026-001',
  'supplierName': '供应商A',
  'submittedByName': '张三',
  'submittedAt': '2026-08-18T02:00:00+08:00',
  'status': 'PENDING',
  'version': 3,
  'allowedActions': <Object>['APPROVE', 'REJECT'],
};

void main() {
  testWidgets('任务卡渲染页内「通过/退回修改」，点通过走订货审批端点', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final task = FinanceProcurementApprovalTask.fromJson(_purchaseTaskJson());
    final fakeRepo = _FakeWorkflowRepo([task]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeOrderApprovalView,
          }),
          // 轮询型角标 provider 换固定值，避免测试期间自刷新。
          financeProcurementApprovalCountProvider.overrideWith(
            (ref) async => 1,
          ),
          financeProcurementWorkflowRepositoryProvider.overrideWithValue(
            fakeRepo,
          ),
        ],
        child: const MaterialApp(home: FinanceProcurementApprovalTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PO-2026-001'), findsOneWidget);
    // 页内审批操作行
    final approveBtn = find.byKey(const Key('finance-approval-approve-case-1'));
    final rejectBtn = find.byKey(const Key('finance-approval-reject-case-1'));
    expect(approveBtn, findsOneWidget, reason: '资格账号应看到「通过」操作');
    expect(rejectBtn, findsOneWidget, reason: '资格账号应看到「退回修改」操作');

    // 点「通过」→ 确认对话框 → 确认 → 恰好发起一次采购订货审批（类型+单据+版本）。
    await tester.tap(approveBtn);
    await tester.pumpAndSettle();
    expect(find.text('确认通过'), findsOneWidget);
    await tester.tap(find.text('确认通过'));
    await tester.pumpAndSettle();
    expect(fakeRepo.approvedOrderIds, hasLength(1), reason: '应恰好审批一次');
    expect(
      fakeRepo.approvedOrderIds.single,
      'FinanceProcurementOrderType.purchase|order-1|v3',
    );
  });

  testWidgets('服务端未放行 allowedActions 时不出页内审批操作', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final json = _purchaseTaskJson()..['allowedActions'] = <Object>[];
    final task = FinanceProcurementApprovalTask.fromJson(json);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeOrderApprovalView,
          }),
          financeProcurementApprovalCountProvider.overrideWith(
            (ref) async => 0,
          ),
          financeProcurementWorkflowRepositoryProvider.overrideWithValue(
            _FakeWorkflowRepo([task]),
          ),
        ],
        child: const MaterialApp(home: FinanceProcurementApprovalTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('finance-approval-approve-case-1')),
      findsNothing,
      reason: '无资格（allowedActions 空）不得出现审批操作',
    );
    expect(
      find.byKey(const Key('finance-approval-reject-case-1')),
      findsNothing,
    );
  });
}
