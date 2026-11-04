import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/providers/expense_counts_provider.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _ScopeApi extends ApiClient {
  _ScopeApi() : super(Dio());
  final reads = <({String path, Map<String, dynamic> query})>[];
  final gates = <String, Completer<Map<String, dynamic>>>{};

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    reads.add((path: path, query: Map.of(query ?? {})));
    if (path.endsWith('/facets')) return Future.value({});
    final key = '${query?['approvalStage']}:${query?['departmentCode']}';
    return gates.putIfAbsent(key, Completer.new).future;
  }
}

Map<String, dynamic> _page(String id) => {
  'items': [
    {
      'id': id,
      'claimNo': id,
      'applicantId': 'applicant',
      'applicantName': '申请人',
      'title': id,
      'totalAmount': 100.0,
      'status': 'SUBMITTED',
      'createdAt': '2026-11-03T08:00:00+08:00',
      'approvalStage': 'DEPARTMENT',
      'canApprove': true,
      'items': <dynamic>[],
    },
  ],
  'page': 1,
  'size': 24,
  'total': 1,
  'totalPages': 1,
};

void main() {
  test(
    'routing stale applications use the action queue without rewriting their status',
    () async {
      final api = _ScopeApi();
      final future = DioExpenseRepository(
        api,
      ).listMineActionRequired(category: 'TRAVEL');
      await Future<void>.delayed(Duration.zero);
      expect(api.reads.single.path, '/expense-claims/mine');
      expect(api.reads.single.query['actionRequired'], isTrue);
      expect(api.reads.single.query.containsKey('status'), isFalse);
      api.gates['null:null']!.complete(_page('routing-stale'));
      expect((await future).items.single.status, ExpenseClaimStatus.submitted);
      expect(
        const ExpenseCounts(
          rejectedCount: 2,
          mineRoutingStaleCount: 3,
        ).actionRequiredCount,
        5,
      );
    },
  );

  test(
    'sibling approval scopes isolate filters, caches and late responses',
    () async {
      final api = _ScopeApi();
      final root = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          apiBaseUrlProvider.overrideWith((ref) => 'https://approval.test/api'),
          masterDataSessionKeyProvider.overrideWithValue('approval-test'),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'reviewer'),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.expenseApproveDepartment,
            Perm.expenseApproveExecutive,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
      );
      final department = ProviderContainer(
        parent: root,
        overrides: [
          expenseApprovalReadScopeProvider.overrideWithValue(
            const ExpenseApprovalReadScope(
              approvalStage: 'DEPARTMENT',
              departmentCode: 'DEPT_SALES',
            ),
          ),
        ],
      );
      final executive = ProviderContainer(
        parent: root,
        overrides: [
          expenseApprovalReadScopeProvider.overrideWithValue(
            const ExpenseApprovalReadScope(approvalStage: 'EXECUTIVE'),
          ),
        ],
      );
      addTearDown(() {
        department.dispose();
        executive.dispose();
        root.dispose();
      });
      final departmentSubscription = department.listen(
        expenseApprovalListProvider,
        (_, _) {},
      );
      final executiveSubscription = executive.listen(
        expenseApprovalListProvider,
        (_, _) {},
      );
      addTearDown(departmentSubscription.close);
      addTearDown(executiveSubscription.close);
      final departmentRead = department.read(
        expenseApprovalListProvider.future,
      );
      final executiveRead = executive.read(expenseApprovalListProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(
        api.reads.map((r) => r.query['approvalStage']),
        containsAll(['DEPARTMENT', 'EXECUTIVE']),
      );
      api.gates['EXECUTIVE:null']!.complete(_page('executive-row'));
      expect((await executiveRead).items.single.id, 'executive-row');
      api.gates['DEPARTMENT:DEPT_SALES']!.complete(_page('department-row'));
      expect((await departmentRead).items.single.id, 'department-row');
      expect(
        executive
            .read(expenseApprovalListProvider)
            .requireValue
            .items
            .single
            .id,
        'executive-row',
      );
      department.read(expenseApprovalFiltersProvider.notifier).state =
          const ExpenseApprovalFilters(category: 'TRAVEL');
      expect(executive.read(expenseApprovalFiltersProvider).category, isNull);
      department.read(approvalQueueProvider.notifier).state =
          ApprovalQueue.history;
      expect(executive.read(approvalQueueProvider), ApprovalQueue.pending);
    },
  );

  test(
    'scope is sent before server pagination for pending, history and facets',
    () async {
      final api = _ScopeApi();
      final repository = DioExpenseRepository(api);
      const scope = ExpenseApprovalReadScope(
        approvalStage: 'DEPARTMENT',
        departmentCode: 'DEPT_ENG',
      );
      final pending = repository.listApprovalScoped(
        ApprovalFacetQueue.pending,
        scope,
        page: 3,
        category: 'TRAVEL',
        sort: 'claimNo',
        order: 'desc',
      );
      await Future<void>.delayed(Duration.zero);
      final query = api.reads.single.query;
      expect(query, containsPair('approvalStage', 'DEPARTMENT'));
      expect(query, containsPair('departmentCode', 'DEPT_ENG'));
      expect(query, containsPair('page', 3));
      expect(query, containsPair('category', 'TRAVEL'));
      api.gates['DEPARTMENT:DEPT_ENG']!.complete(_page('row'));
      await pending;
      await repository.facetsScoped(ApprovalFacetQueue.history, scope);
      expect(api.reads.last.query, containsPair('queue', 'history'));
      expect(api.reads.last.query, containsPair('departmentCode', 'DEPT_ENG'));
      expect(ExpenseFilter.values.first, ExpenseFilter.draft);
      expect(ExpenseClaimStatus.submitted.apiValue, 'SUBMITTED');
    },
  );
}
