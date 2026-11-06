import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/payroll/models/payroll_batch.dart';
import 'package:uten_imp/features/payroll/pages/payroll_review_page.dart';
import 'package:uten_imp/features/payroll/providers/payroll_providers.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  test(
    'complete batches retain scope on refresh and retire an active continuation after history is chosen',
    () async {
      final repo = _Repository();
      final container = ProviderContainer(
        overrides: [
          payrollRepositoryProvider.overrideWithValue(repo),
          masterDataSessionKeyProvider.overrideWithValue('test'),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        payrollBatchListProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final initial = await container.read(payrollBatchListProvider.future);
      expect(initial.items, hasLength(2));
      expect(initial.totalPages, 1);
      expect(repo.requests, [('ACTIVE', 1), ('ACTIVE', 2)]);
      await container.read(payrollBatchListProvider.notifier).refresh();
      expect(repo.requests.last, ('ACTIVE', 2));
      repo.pendingActivePage = Completer();
      final old = container.read(payrollBatchListProvider.notifier).refresh();
      await Future<void>.delayed(Duration.zero);
      container.read(payrollBatchScopeProvider.notifier).state =
          PayrollBatchScope.history;
      final history = await container.read(payrollBatchListProvider.future);
      expect(history.items, hasLength(2));
      expect(
        history.items.every(
          (batch) => batch.status == PayrollBatchStatus.published,
        ),
        true,
      );
      repo.pendingActivePage!.complete(_page('ACTIVE', 2));
      await old;
      expect(
        container
            .read(payrollBatchListProvider)
            .requireValue
            .items
            .every((batch) => batch.status == PayrollBatchStatus.published),
        true,
      );
      await container.read(payrollBatchListProvider.notifier).refresh();
      expect(repo.requests.last, ('HISTORY', 2));
    },
  );

  testWidgets(
    'approved batches still await publication; history remains browse-only',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repo = _Repository();
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            payrollRepositoryProvider.overrideWithValue(repo),
            sharedPreferencesProvider.overrideWithValue(preferences),
            masterDataSessionKeyProvider.overrideWithValue('test'),
            currentPermissionsProvider.overrideWithValue({Perm.payrollPublish}),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PayrollReviewPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.requests.last, ('ACTIVE', 2));
      expect(find.text('发布工资条'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      await tester.tap(find.text('历史单据'));
      await tester.pumpAndSettle();
      expect(repo.requests.last, ('HISTORY', 2));
      expect(find.text('发布工资条'), findsNothing);
      expect(find.text('已发布'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Repository extends Fake implements PayrollRepository {
  final requests = <(String?, int)>[];
  Completer<PagedResult<PayrollBatch>>? pendingActivePage;
  @override
  Future<PagedResult<PayrollBatch>> listBatches({
    int page = 1,
    int size = 20,
    int? year,
    int? month,
    String? status,
    String? departmentId,
  }) async {
    requests.add((status, page));
    if (status == 'ACTIVE' && page == 2 && pendingActivePage != null) {
      return pendingActivePage!.future;
    }
    return _page(status!, page);
  }

  @override
  Future<PayrollBatch> getBatch(String id) async =>
      _batch(id.startsWith('HISTORY') ? 'HISTORY' : 'ACTIVE', id: id);
}

PayrollBatch _batch(String scope, {String? id}) => PayrollBatch(
  id: id ?? '$scope-batch',
  year: 2026,
  month: 10,
  status: scope == 'HISTORY'
      ? PayrollBatchStatus.published
      : PayrollBatchStatus.approved,
  headcount: 1,
  grossIncome: 100,
  totalDeduction: 10,
  netIncome: 90,
);
PagedResult<PayrollBatch> _page(String scope, int page) => PagedResult(
  items: [_batch(scope, id: '$scope-batch-$page')],
  page: page,
  size: 1,
  total: 2,
  totalPages: 2,
);
