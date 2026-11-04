import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/pages/expense_detail_page.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/expense/widgets/expense_claim_print.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'owner',
      employeeId: 'employee',
      name: '申请人',
      code: 'E01',
      permissions: [Perm.expenseApply],
    ),
  );
}

ExpenseClaim claim({bool abandoned = false}) => ExpenseClaim(
  id: 'claim',
  claimNo: 'BX20261103000001',
  applicantId: 'employee',
  applicantName: '申请人',
  title: '驳回后已保存的修订',
  items: [
    ExpenseItem(
      id: 'item',
      category: ExpenseCategory.travel,
      amount: 12.5,
      date: DateTime(2026, 11, 3),
      description: '本次已保存用途',
    ),
  ],
  totalAmount: 12.5,
  status: ExpenseClaimStatus.rejected,
  createdAt: DateTime(2026, 11, 3),
  version: 3,
  rejectReason: '补充住宿原件',
  abandoned: abandoned,
);

class _Repo extends Fake implements ExpenseRepository {
  bool abandoned = false;
  int writes = 0;
  int historyReads = 0;
  int? sentVersion;
  @override
  Future<ExpenseClaim> getById(String id) async => claim(abandoned: abandoned);
  @override
  Future<ExpenseClaim> getHistoryById(String id) async {
    historyReads++;
    return claim(abandoned: true);
  }

  @override
  Future<ExpenseClaim> abandon(String id, {int? expectedVersion}) async {
    writes++;
    sentVersion = expectedVersion;
    abandoned = true;
    return claim(abandoned: true);
  }
}

class _Fields extends Fake implements PlatformTableRepository {
  int historyReads = 0;
  int liveReads = 0;
  @override
  Future<PlatformRowValues> latestHistory(String scope, String id) async {
    historyReads++;
    return PlatformRowValues(
      recordId: id,
      version: 2,
      cells: [
        const PlatformColumnCell(
          columnId: 'saved-note',
          value: '驳回后修订的历史值',
          definition: PlatformColumnDefinition(
            id: 'saved-note',
            name: '历史说明',
            scope: 'expense_claim_item',
          ),
        ),
      ],
    );
  }

  @override
  Future<List<PlatformTableCapabilities>> scopes() async => const [
    PlatformTableCapabilities(scope: 'expense_claim_item', priceVisible: true),
  ];
  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async => [];
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    liveReads++;
    throw StateError('archive must not read live values');
  }
}

void main() {
  testWidgets(
    'owner abandons rejected claim once and enters read-only native field history',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repository = _Repo();
      final fields = _Fields();
      final projection = TableColumnProjectionController();
      addTearDown(projection.dispose);
      final router = GoRouter(
        initialLocation: '/expense/claim',
        routes: [
          GoRoute(
            path: '/expense/:id',
            builder: (_, s) => ExpenseDetailPage(
              claimId: s.pathParameters['id']!,
              history: s.uri.queryParameters['history'] == '1',
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_Session.new),
            sharedPreferencesProvider.overrideWithValue(prefs),
            apiBaseUrlProvider.overrideWithValue(
              'https://expense-history.test/api',
            ),
            apiClientProvider.overrideWithValue(
              ApiClient(
                Dio(BaseOptions(baseUrl: 'https://expense-history.test/api')),
              ),
            ),
            expenseRepositoryProvider.overrideWithValue(repository),
            platformTableRepositoryProvider.overrideWithValue(fields),
            expenseSettingsProvider.overrideWith(
              (ref) async => const ExpenseSettings(companyName: '示例公司'),
            ),
          ],
          child: MaterialApp.router(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
            builder: (context, child) => TableColumnProjectionScope(
              controller: projection,
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃报销'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃并归档'));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(repository.sentVersion, 3);
      expect(repository.historyReads, greaterThan(0));
      expect(fields.historyReads, 1);
      expect(fields.liveReads, 0);
      expect(find.text('报销归档详情'), findsOneWidget);
      expect(find.text('重新提交'), findsNothing);
      expect(find.text('编辑'), findsNothing);
      expect(find.text('放弃报销'), findsNothing);
      await tester.tap(find.byKey(const Key('expense-detail-print')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('预览 · 费用报销单'),
        findsOneWidget,
        reason:
            'the real AppBar must resolve the archived editable-grid schema projection',
      );
      expect(find.textContaining('找不到报销明细的列设置'), findsNothing);
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'abandoned printing uses latest saved native values without live definitions or last submission rows',
    () async {
      final original = claim(abandoned: true);
      const snapshot = PlatformRowValues(
        recordId: 'item',
        cells: [
          PlatformColumnCell(
            columnId: 'old',
            value: '已保存修订',
            definition: PlatformColumnDefinition(
              id: 'old',
              scope: 'expense_claim_item',
              name: '原说明',
            ),
          ),
          PlatformColumnCell(
            columnId: 'formula',
            error: '历史结果不能重算',
            definition: PlatformColumnDefinition(
              id: 'formula',
              scope: 'expense_claim_item',
              name: '历史计算',
              type: 'CALCULATED',
            ),
          ),
        ],
      );
      final archived = original.copyWith(
        items: [original.items.single.withPlatformFields(snapshot.toJson())],
      );
      final table = await expensePrintItemsTable(
        archived,
        projection: const TableColumnProjection(
          tableKey: 'expense.claim.items',
          columns: [
            TableProjectedColumn(
              key: 'description',
              label: '用途',
              width: 200,
              type: 'text',
            ),
            TableProjectedColumn(
              key: 'platform:old',
              label: '原说明',
              width: 100,
              type: 'text',
            ),
            TableProjectedColumn(
              key: 'platform:formula',
              label: '历史计算',
              width: 100,
              type: 'text',
            ),
          ],
        ),
      );
      expect(table.rows, [
        ['本次已保存用途', '已保存修订', '历史结果未保存'],
      ]);
      expect(archived.progressLabel, '已放弃');
    },
  );
}
