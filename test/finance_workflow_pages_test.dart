import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_tasks_page.dart';
import 'package:uten_imp/features/finance/pages/finance_workflow_responsibilities_page.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('finance hub shows personal approval card and managed settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    final repository = _FakeWorkflowRepository(count: 3);
    await _pump(
      tester,
      const FinanceHubPage(),
      repository: repository,
      permissions: const {
        Perm.financeOrderApprovalView,
        Perm.workflowAssignmentManage,
      },
    );

    expect(find.text('订货审批任务中心'), findsOneWidget);
    expect(find.text('审批负责人设置'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('settings entry is hidden without workflow manage permission', (
    tester,
  ) async {
    await _pump(
      tester,
      const FinanceHubPage(),
      repository: _FakeWorkflowRepository(),
      permissions: const {Perm.financeOrderApprovalView},
    );

    expect(find.text('订货审批任务中心'), findsOneWidget);
    expect(find.text('审批负责人设置'), findsNothing);
  });

  testWidgets('task page remains readable at compact width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    await _pump(
      tester,
      const FinanceProcurementApprovalTasksPage(),
      repository: _FakeWorkflowRepository(),
      permissions: const {Perm.financeOrderApprovalView},
    );

    expect(find.text('PO-001'), findsOneWidget);
    expect(find.textContaining('示例供应商'), findsOneWidget);
    expect(find.textContaining('900.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('responsibility save requires password and sends version', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 1000));
    final repository = _FakeWorkflowRepository();
    await _pump(
      tester,
      const FinanceWorkflowResponsibilitiesPage(),
      repository: repository,
      permissions: const {Perm.workflowAssignmentManage},
    );

    expect(find.text('只有此人会收到并可处理'), findsNWidgets(2));
    final picker = find.byKey(
      const ValueKey('workflow-reviewer-PURCHASE_ORDER_FINANCE_APPROVAL'),
    );
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('李四').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workflow-responsibility-save')));
    await tester.pumpAndSettle();
    expect(repository.updateCalls, 0);
    await tester.enterText(
      find.byKey(const Key('workflow-responsibility-password')),
      'Current-Password',
    );
    await tester.tap(
      find.byKey(const Key('workflow-responsibility-password-confirm')),
    );
    await tester.pumpAndSettle();

    expect(repository.updateCalls, 1);
    expect(repository.lastBehavior, 'PURCHASE_ORDER_FINANCE_APPROVAL');
    expect(repository.lastAssignee, 'user-2');
    expect(repository.lastExpectedVersion, 3);
    expect(repository.lastPassword, 'Current-Password');
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required _FakeWorkflowRepository repository,
  required Set<String> permissions,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        financeProcurementWorkflowRepositoryProvider.overrideWithValue(
          repository,
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeWorkflowRepository implements FinanceProcurementWorkflowRepository {
  _FakeWorkflowRepository({this.count = 1});

  final int count;
  int updateCalls = 0;
  String? lastBehavior;
  String? lastAssignee;
  int? lastExpectedVersion;
  String? lastPassword;

  List<FinanceWorkflowResponsibility> _responsibilities = const [
    FinanceWorkflowResponsibility(
      behaviorCode: 'PURCHASE_ORDER_FINANCE_APPROVAL',
      assigneeUserId: 'user-1',
      assigneeName: '张三',
      assigneeDepartmentName: '财务部',
      version: 3,
    ),
    FinanceWorkflowResponsibility(
      behaviorCode: 'SUBCONTRACT_ORDER_FINANCE_APPROVAL',
      assigneeUserId: 'user-1',
      assigneeName: '张三',
      assigneeDepartmentName: '财务部',
      version: 2,
    ),
  ];

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
  }) async {
    return FinanceProcurementApprovalPage(
      items: const [
        FinanceProcurementApprovalTask(
          caseId: 'case-1',
          orderId: 'order-1',
          orderType: FinanceProcurementOrderType.purchase,
          billNo: 'PO-001',
          supplierName: '示例供应商',
          submittedByName: '采购员甲',
          amount: '900.00',
          currencyName: 'CNY',
          submittedAt: '2026-08-02T10:30:00+08:00',
        ),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<int> pendingApprovalCount() async => count;

  @override
  Future<List<FinanceWorkflowResponsibility>> responsibilities() async =>
      _responsibilities;

  @override
  Future<List<FinanceWorkflowReviewer>> reviewers() async => const [
    FinanceWorkflowReviewer(
      userId: 'user-1',
      employeeId: 'employee-1',
      employeeName: '张三',
      departmentName: '财务部',
    ),
    FinanceWorkflowReviewer(
      userId: 'user-2',
      employeeId: 'employee-2',
      employeeName: '李四',
      departmentName: '财务部',
    ),
  ];

  @override
  Future<FinanceWorkflowResponsibility> updateResponsibility({
    required String behaviorCode,
    required String assigneeUserId,
    required int expectedVersion,
    required String password,
  }) async {
    updateCalls++;
    lastBehavior = behaviorCode;
    lastAssignee = assigneeUserId;
    lastExpectedVersion = expectedVersion;
    lastPassword = password;
    final updated = FinanceWorkflowResponsibility(
      behaviorCode: behaviorCode,
      assigneeUserId: assigneeUserId,
      assigneeName: assigneeUserId == 'user-2' ? '李四' : '张三',
      assigneeDepartmentName: '财务部',
      version: expectedVersion + 1,
      updatedAt: '2026-08-02T11:00:00+08:00',
    );
    _responsibilities = [
      for (final responsibility in _responsibilities)
        if (responsibility.behaviorCode == behaviorCode)
          updated
        else
          responsibility,
    ];
    return updated;
  }
}
