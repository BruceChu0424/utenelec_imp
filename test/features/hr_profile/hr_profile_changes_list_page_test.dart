// HR 信息变更队列（2026-09-10 表头筛选接后端 + 批量驳回）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_batch_reject_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/hr_profile/pages/hr_profile_changes_list_page.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';
import 'package:uten_imp/features/profile/repositories/profile_change_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _FakeProfileChangeRepository extends Fake
    implements ProfileChangeRepository {
  final List<Map<String, dynamic>> listCalls = [];
  final List<List<String>> reviewCalls = [];

  @override
  Future<ProfileChangePage<HrProfileChangeListItem>> hrList({
    int page = 1,
    int size = 20,
    String? status,
    String? employeeId,
    String? departmentId,
  }) async {
    listCalls.add({
      'page': page,
      'status': status,
      'departmentId': departmentId,
    });
    return ProfileChangePage(
      items: [
        HrProfileChangeListItem(
          batchId: 'batch-1',
          employeeId: 'emp-1',
          employeeName: '王小明',
          employeeCode: 'UT0001',
          departmentName: '研发部',
          status: ProfileChangeStatus.pending,
          itemCount: 2,
          fieldCodes: const ['phone', 'email'],
          submittedAt: DateTime(2026, 9, 9, 10, 30),
        ),
        HrProfileChangeListItem(
          batchId: 'batch-2',
          employeeId: 'emp-2',
          employeeName: '李小红',
          employeeCode: 'UT0002',
          departmentName: '财务部',
          status: ProfileChangeStatus.pending,
          itemCount: 1,
          fieldCodes: const ['address'],
          submittedAt: DateTime(2026, 9, 9, 11, 30),
        ),
      ],
      page: page,
      size: size,
      total: 2,
      totalPages: 1,
    );
  }

  @override
  Future<Map<String, List<MasterFacetBucket>>> hrFacets({
    String? status,
  }) async => {
    'departmentName': const [
      MasterFacetBucket(value: 'dept-1', count: 3, label: '研发部'),
      MasterFacetBucket(value: 'dept-2', count: 1, label: '财务部'),
    ],
  };

  @override
  Future<ProfileChangeBatch> review(
    String batchId,
    String action,
    String? comment,
  ) async {
    reviewCalls.add([batchId, action, comment ?? '']);
    return ProfileChangeBatch(
      batchId: batchId,
      employeeId: 'emp-1',
      status: ProfileChangeStatus.rejected,
      itemCount: 1,
      items: const [],
      submittedAt: DateTime(2026, 9, 9),
    );
  }

  @override
  Future<int> hrPendingCount() async => 0;
}

Widget _app(_FakeProfileChangeRepository repo) => ProviderScope(
  overrides: [
    profileChangeRepositoryProvider.overrideWithValue(repo),
    currentPermissionsProvider.overrideWithValue({Perm.profileReview}),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HrProfileChangesListPage(),
  ),
);

MasterDataTableView<HrProfileChangeListItem> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<HrProfileChangeListItem>>(
      find.byWidgetPredicate(
        (w) => w is MasterDataTableView<HrProfileChangeListItem>,
      ),
    );

void main() {
  testWidgets('department header facet is pushed to the backend query', (
    tester,
  ) async {
    final repo = _FakeProfileChangeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.facets['departmentName']!.map((b) => b.value), [
      'dept-1',
      'dept-2',
    ]);
    expect(table.filters['status'], 'pending');

    table.onFilterChanged('departmentName', 'dept-1');
    await tester.pumpAndSettle();

    expect(repo.listCalls.last['departmentId'], 'dept-1');
    expect(repo.listCalls.last['page'], 1, reason: '换筛选回第 1 页');
    expect(_table(tester).filters['departmentName'], 'dept-1');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status header facet switches the queue segment', (tester) async {
    final repo = _FakeProfileChangeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    _table(tester).onFilterChanged('status', 'rejected');
    await tester.pumpAndSettle();

    expect(repo.listCalls.last['status'], 'rejected');
    expect(repo.listCalls.last['page'], 1);
    // 非待审段只读：不再开多选批量
    expect(_table(tester).selectable, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('batch reject applies one shared reason to every batch', (
    tester,
  ) async {
    final repo = _FakeProfileChangeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.selectable, isTrue, reason: '待审段开多选');
    table.onSelectedIdsChanged!({'batch-1', 'batch-2'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('hr-profile-changes-batch-reject')));
    await tester.pumpAndSettle();

    expect(find.byType(UtenBatchRejectDialog), findsOneWidget);
    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
      reason: '批量驳回弹窗须带审核责任提示',
    );

    // 空原因不关闭对话框
    await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(UtenBatchRejectDialog), findsOneWidget);
    expect(repo.reviewCalls, isEmpty);

    await tester.enterText(
      find.byKey(const Key('uten-batch-reject-reason')),
      '身份证号与档案不符',
    );
    await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
    await tester.pumpAndSettle();

    expect(repo.reviewCalls.length, 2);
    expect(repo.reviewCalls.map((c) => c[0]).toSet(), {'batch-1', 'batch-2'});
    expect(repo.reviewCalls.every((c) => c[1] == 'reject'), isTrue);
    expect(repo.reviewCalls.every((c) => c[2] == '身份证号与档案不符'), isTrue);

    await tester.pumpWidget(const SizedBox());
  });
}
