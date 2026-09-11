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
  }) async {
    listCalls.add({'page': page, 'status': status});
    return ProfileChangePage(
      items: [
        MyProfileChangeListItem(
          batchId: 'batch-1',
          status: ProfileChangeStatus.pending,
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
    ]);
    expect(table.filters['status'], isNull, reason: '「全部」段不选中任何状态');

    table.onFilterChanged('status', 'rejected');
    await tester.pumpAndSettle();

    expect(repo.listCalls.last['status'], 'rejected');
    expect(repo.listCalls.last['page'], 1);

    await tester.pumpWidget(const SizedBox());
  });
}
