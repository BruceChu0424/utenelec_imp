import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_list_page.dart';
import 'package:uten_imp/features/expense/pages/expense_list_page.dart';
import 'package:uten_imp/features/hr_profile/pages/hr_profile_changes_list_page.dart';
import 'package:uten_imp/features/hr_task/pages/hr_task_list_page.dart';
import 'package:uten_imp/features/hr_task/widgets/hr_task_widgets.dart';
import 'package:uten_imp/features/payroll/pages/payroll_review_page.dart';
import 'package:uten_imp/features/payroll/pages/payroll_slip_list_page.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/features/suggestion/pages/suggestion_list_page.dart';
import 'package:uten_imp/features/visitor_approval/pages/my_visitors_page.dart';
import 'package:uten_imp/features/visitor_approval/pages/visitor_approval_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';
import '../support/filter_segment_tap.dart';

void main() {
  final scenarios =
      <({String name, Widget page, String path, String? segment})>[
        (
          name: '工资条',
          page: const PayrollSlipListPage(),
          path: '/payroll/slips',
          segment: '已查看',
        ),
        (
          name: '工资批次',
          page: const PayrollReviewPage(),
          path: '/payroll/batches',
          segment: '历史单据',
        ),
        (
          name: '资料修改审批',
          page: const HrProfileChangesListPage(),
          path: '/hr/profile-changes',
          segment: '历史单据',
        ),
        (
          name: '访客审批',
          page: const VisitorApprovalListPage(),
          path: '/visitor-approval',
          segment: '历史单据',
        ),
        (
          name: '我的访客',
          page: const MyVisitorsPage(),
          path: '/visitor-approval/as-host',
          segment: '历史单据',
        ),
        (
          name: '我的报销',
          page: const ExpenseListPage(),
          path: '/expense-claims/mine',
          segment: '历史单据',
        ),
        (
          name: '报销审批',
          page: const ExpenseApprovalListPage(),
          path: '/expense-claims/pending',
          segment: '已处理',
        ),
        (
          name: '建议箱',
          page: const SuggestionListPage(),
          path: '/suggestions',
          segment: '我的建议',
        ),
        (
          name: '研发任务',
          page: const RdTaskPage(),
          path: '/rd-tasks',
          segment: '历史单据',
        ),
        (
          name: '人事任务',
          page: const HrTaskListPage(type: HrTaskType.confirm),
          path: '/org/hr-tasks/summary',
          segment: null,
        ),
      ];
  for (final scenario in scenarios) {
    testWidgets(
      '${scenario.name} displays its real columns while reads and category changes are pending',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _GatedApi(scenario.path);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.employeeView,
                Perm.employeeEdit,
                Perm.expenseApply,
                Perm.expenseApprove,
                Perm.visitorApprove,
                Perm.visitorHostConfirm,
                Perm.payrollReview,
                Perm.payrollViewSelf,
              }),
              fixedBadgeSummaryOverride(),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: scenario.page,
            ),
          ),
        );
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final tables = find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView,
        );
        expect(
          api.reads,
          isNotEmpty,
          reason: 'the business request is deliberately still pending',
        );
        expect(tables, findsOneWidget);
          MasterDataTableView<dynamic> table = tester.widget(tables);
        expect(table.columns, isNotEmpty);
        expect(table.items, isEmpty);
        expect(table.isLoading, isTrue);
        final segment = scenario.segment;
        if (segment != null) {
          await selectFilterSegment(tester, segment);
          await tester.pump(const Duration(milliseconds: 16));
          table = tester.widget(tables);
          expect(table.columns, isNotEmpty);
          expect(table.items, isEmpty);
          expect(table.isLoading, isTrue);
          expect(api.reads.length, greaterThanOrEqualTo(2));
        }
        for (final request in api.reads) {
          request.complete(_emptyPage);
        }
        await tester.pumpAndSettle();
        table = tester.widget(tables);
        expect(table.isLoading, isFalse);
        expect(table.items, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

const _emptyPage = <String, dynamic>{
  'items': <Object?>[],
  'page': 1,
  'size': 20,
  'total': 0,
  'totalElements': 0,
  'totalPages': 0,
};

class _GatedApi extends ApiClient {
  _GatedApi(this.path) : super(Dio());
  final String path;
  final reads = <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> get(
    String route, {
    Map<String, dynamic>? query,
  }) async {
    final expenseList =
        path.startsWith('/expense-claims/') &&
        const {
          '/expense-claims/mine',
          '/expense-claims/pending',
          '/expense-claims/payable',
          '/expense-claims/history',
        }.contains(route);
    if (route == path || expenseList) {
      final result = Completer<Map<String, dynamic>>();
      reads.add(result);
      return result.future;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}
