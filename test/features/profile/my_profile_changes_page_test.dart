// 我的信息变更（2026-09-10 状态表头筛选 = 分段口径，下推后端并回第 1 页）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';
import 'package:uten_imp/features/profile/pages/my_profile_changes_page.dart';
import 'package:uten_imp/features/profile/repositories/profile_change_repository.dart';

class _FakeProfileChangeRepository extends Fake
    implements ProfileChangeRepository {
  final List<Map<String, dynamic>> listCalls = [];

  @override
  Future<ProfileChangePage<MyProfileChangeListItem>> myList({
    int page = 1,
    int size = 20,
    String? status,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
  }) async {
    listCalls.add({'page': page, 'status': status, ...columns, 'sort': ?sort});
    return ProfileChangePage(
      items: [
        MyProfileChangeListItem(
          batchId: 'batch-1',
          status: status == 'pending'
              ? ProfileChangeStatus.pending
              : status == 'rejected'
              ? ProfileChangeStatus.rejected
              : ProfileChangeStatus.applied,
          itemCount: 1,
          submittedAt: DateTime(2026, 9, 10, 9),
          fieldCodes: const ['phone'],
          fieldLabels: const ['手机号'],
        ),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }
}

void main() {
  testWidgets('status header facet is pushed to the backend query', (
    tester,
  ) async {
    final repo = _FakeProfileChangeRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [profileChangeRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MyProfileChangesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<MyProfileChangeListItem>>(
      find.byKey(const Key('my-profile-changes-table')),
    );
    expect(table.facets['status']!.map((b) => b.value), [
      'pending',
      'applied',
      'rejected',
      'approved',
      'cancelled',
    ]);
    expect(table.filters['status'], 'pending');
    expect(repo.listCalls.last['status'], 'pending');

    table.onFilterChanged('status', 'rejected');
    await tester.pumpAndSettle();

    expect(repo.listCalls.last['status'], 'rejected');
    expect(repo.listCalls.last['page'], 1);
    var historyTable = tester
        .widget<MasterDataTableView<MyProfileChangeListItem>>(
          find.byKey(const Key('my-profile-changes-table')),
        );
    expect(
      historyTable.rowMenuBuilder!(historyTable.items.single),
      hasLength(1),
      reason: '历史只能查看差异，不可撤销',
    );
    historyTable.onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(repo.listCalls.last['status'], 'history', reason: '清除历史子状态仍留在历史范围');
    await tester.tap(find.text('历史单据'));
    await tester.pumpAndSettle();
    historyTable = tester.widget<MasterDataTableView<MyProfileChangeListItem>>(
      find.byKey(const Key('my-profile-changes-table')),
    );
    expect(historyTable.filters['status'], isNull);
    await tester.tap(find.text('项数'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      '1',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repo.listCalls.last['search.itemCount'], '1');
    expect(repo.listCalls.last['status'], 'history');
    expect(repo.listCalls.last['page'], 1);

    await tester.pumpWidget(const SizedBox());
  });
}
