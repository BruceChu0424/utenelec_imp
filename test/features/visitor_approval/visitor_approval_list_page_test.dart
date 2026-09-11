// 访客审批列表（2026-09-10 表头筛选接后端 + 批量拒绝/转接待人）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_batch_reject_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/visitor/models/visitor_application.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_staff_repository.dart';
import 'package:uten_imp/features/visitor_approval/pages/visitor_approval_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakeVisitorStaffRepository extends Fake
    implements VisitorStaffRepository {
  final List<Map<String, dynamic>> listCalls = [];
  final List<Map<String, dynamic>> actionCalls = [];

  @override
  Future<PagedResult<VisitorApplication>> approvalList({
    String? status,
    String? hostDepartmentId,
    int page = 1,
    int size = 20,
  }) async {
    listCalls.add({
      'status': status,
      'hostDepartmentId': hostDepartmentId,
      'page': page,
    });
    return PagedResult(
      items: [
        _application('app-1', VisitorApplicationStatus.pending),
        _application('app-2', VisitorApplicationStatus.hostReviewing),
      ],
      page: page,
      size: size,
      total: 2,
      totalPages: 1,
    );
  }

  @override
  Future<Map<String, List<MasterFacetBucket>>> approvalFacets({
    String? status,
  }) async => {
    'status': const [
      MasterFacetBucket(value: 'pending', count: 5, label: 'pending'),
      MasterFacetBucket(
        value: 'hostReviewing',
        count: 2,
        label: 'hostReviewing',
      ),
    ],
    'hostDepartment': const [
      MasterFacetBucket(value: 'dept-1', count: 4, label: '研发部'),
    ],
  };

  @override
  Future<VisitorApplication> action(
    String id, {
    required String action,
    String? comment,
    String? rejectReason,
  }) async {
    actionCalls.add({'id': id, 'action': action, 'rejectReason': rejectReason});
    return _application(id, VisitorApplicationStatus.rejected);
  }

  @override
  Future<int> pendingCount() async => 0;
}

VisitorApplication _application(String id, VisitorApplicationStatus status) =>
    VisitorApplication(
      id: id,
      visitorName: '访客$id',
      visitPurpose: '洽谈',
      status: status,
      plannedVisitAt: DateTime(2026, 9, 11, 9),
      appliedAt: DateTime(2026, 9, 10, 9),
      company: '外部公司',
      hostName: '王小明',
      hostDepartment: '研发部',
    );

Widget _app(_FakeVisitorStaffRepository repo, SharedPreferences preferences) =>
    ProviderScope(
      overrides: [
        visitorStaffRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({Perm.visitorApprove}),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: VisitorApprovalListPage(),
      ),
    );

MasterDataTableView<VisitorApplication> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<VisitorApplication>>(
      find.byWidgetPredicate(
        (w) => w is MasterDataTableView<VisitorApplication>,
      ),
    );

void main() {
  testWidgets('status/department header facets are pushed to the backend', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeVisitorStaffRepository();
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.facets['status']!.map((b) => b.value), [
      'pending',
      'hostReviewing',
    ]);
    // 后端只给状态码，页面按 l10n 重贴中文标签
    expect(table.facets['status']!.first.label, isNot('pending'));
    expect(table.facets['hostDepartment']!.single.value, 'dept-1');

    table.onFilterChanged('hostDepartment', 'dept-1');
    await tester.pumpAndSettle();
    expect(repo.listCalls.last['hostDepartmentId'], 'dept-1');
    expect(repo.listCalls.last['page'], 1);

    _table(tester).onFilterChanged('status', 'hostReviewing');
    await tester.pumpAndSettle();
    expect(repo.listCalls.last['status'], 'hostReviewing');
    expect(
      repo.listCalls.last['hostDepartmentId'],
      'dept-1',
      reason: '状态与部门两列筛选正交，互不清除',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('batch reject sends one shared reason per application', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeVisitorStaffRepository();
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    _table(tester).onSelectedIdsChanged!({'app-1', 'app-2'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('visitor-approval-batch-reject')));
    await tester.pumpAndSettle();
    expect(find.byType(UtenBatchRejectDialog), findsOneWidget);
    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('uten-batch-reject-reason')),
      '来访事由不明确',
    );
    await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
    await tester.pumpAndSettle();

    expect(repo.actionCalls.length, 2);
    expect(repo.actionCalls.every((c) => c['action'] == 'reject'), isTrue);
    expect(
      repo.actionCalls.every((c) => c['rejectReason'] == '来访事由不明确'),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('batch forward skips applications already with the host', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeVisitorStaffRepository();
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    _table(tester).onSelectedIdsChanged!({'app-1', 'app-2'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('visitor-approval-batch-forward')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已在接待人确认中，已跳过'), findsOneWidget);
    await tester.tap(find.text('确认批量转接'));
    await tester.pumpAndSettle();

    // app-2 已是 hostReviewing，前端跳过，不发请求
    expect(repo.actionCalls.length, 1);
    expect(repo.actionCalls.single['id'], 'app-1');
    expect(repo.actionCalls.single['action'], 'forward');

    await tester.pumpWidget(const SizedBox());
  });
}
