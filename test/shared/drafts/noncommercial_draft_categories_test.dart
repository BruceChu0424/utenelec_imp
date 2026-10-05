import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/pages/expense_list_page.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_inbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_form_draft_categories.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_drafts_panel.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

FormDraft _draft(
  String id,
  BadgeModule module,
  String route, {
  String? kind,
  Map<String, dynamic> data = const {},
}) => FormDraft(
  id: id,
  title: '填写草稿 $id',
  module: module,
  route: route,
  permission: '',
  draftKind: kind,
  data: data,
  updatedAt: DateTime.utc(2026, 9, 26),
);

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.values);
  final List<FormDraft> values;
  @override
  List<FormDraft> build() => values;
}

void main() {
  testWidgets(
    'finance draft category combines local input with formal draft without duplicate created row',
    (tester) async {
      await _pump(
        tester,
        const FinanceDocListPage(
          docType: FinanceDocType.expense,
          initialStatus: 'draft',
        ),
        '/finance/expenses',
        [
          _draft(
            'expense-local',
            BadgeModule.finance,
            '/finance/expenses/new',
            kind: 'financeExpense',
          ),
          _draft(
            'created-local',
            BadgeModule.finance,
            '/finance/expenses/new',
            kind: 'financeExpense',
            data: {'createdDocId': 'formal-1'},
          ),
          _draft(
            'receipt-local',
            BadgeModule.finance,
            '/finance/receipts/new',
            kind: 'financeReceipt',
          ),
        ],
      );
      final table = tester
          .widget<
            MasterDataTableView<FormDraftCategoryRow<FinanceDocListItem>>
          >(
            find.byType(
              MasterDataTableView<FormDraftCategoryRow<FinanceDocListItem>>,
            ),
          );
      expect([...table.unpagedItems, ...table.items].length, 2);
      expect(
        [
          ...table.unpagedItems,
          ...table.items,
        ].where((row) => row.isLocal).single.draft!.id,
        'expense-local',
      );
      expect(
        [
          ...table.unpagedItems,
          ...table.items,
        ].where((row) => !row.isLocal).single.draft!.id,
        'created-local',
      );
      final filters = tester.widget<UtenFilterToolbar<int?>>(
        find.byType(UtenFilterToolbar<int?>),
      );
      expect(
        filters.segments.singleWhere((segment) => segment.label == '草稿').count,
        2,
      );
      expect(find.byType(FormDraftsPanel), findsNothing);
      filters.onSelectionChanged!(1);
      await tester.pumpAndSettle();
      expect(
        find.byType(
          MasterDataTableView<FormDraftCategoryRow<FinanceDocListItem>>,
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline finance list keeps its draft category and local rows usable',
    (tester) async {
      await _pump(
        tester,
        const FinanceDocListPage(
          docType: FinanceDocType.expense,
          initialStatus: 'draft',
        ),
        '/finance/expenses',
        [
          _draft(
            'offline-local',
            BadgeModule.finance,
            '/finance/expenses/new',
            kind: 'financeExpense',
          ),
        ],
        failFinance: true,
      );
      final table = tester
          .widget<
            MasterDataTableView<FormDraftCategoryRow<FinanceDocListItem>>
          >(
            find.byType(
              MasterDataTableView<FormDraftCategoryRow<FinanceDocListItem>>,
            ),
          );
      expect(
        [...table.unpagedItems, ...table.items].single.draft!.id,
        'offline-local',
      );
      expect(table.onRowTap, isNotNull);
      expect(table.isLoading, isFalse);
      expect(
        table.error,
        'offline',
        reason: 'pagination must retain its failed request for retry',
      );
      expect(
        find.byKey(const ValueKey('form-draft-row-offline-local')),
        findsOneWidget,
        reason:
            'offline server errors must not replace the recoverable input row',
      );
      expect(find.byType(UtenFilterToolbar<int?>), findsOneWidget);
      expect(find.byType(FormDraftsPanel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expense local inputs only appear after choosing its existing draft category',
    (tester) async {
      await _pump(tester, const ExpenseListPage(), '/expense', [
        _draft(
          'claim-local',
          BadgeModule.people,
          '/expense/new',
          kind: 'expense',
          data: {'title': '差旅填写中'},
        ),
        _draft('onboarding-local', BadgeModule.people, '/employee/onboarding'),
      ]);
      expect(find.byType(FormDraftCategoryTable<ExpenseClaim>), findsNothing);
      expect(find.byType(FormDraftsPanel), findsNothing);
      final toolbar = tester.widget<UtenFilterToolbar<ExpenseFilter>>(
        find.byType(UtenFilterToolbar<ExpenseFilter>),
      );
      expect(
        toolbar.segments.singleWhere((segment) => segment.label == '草稿').count,
        1,
      );
      toolbar.onSelectionChanged!(ExpenseFilter.draft);
      await tester.pumpAndSettle();
      final table = tester
          .widget<MasterDataTableView<FormDraftCategoryRow<ExpenseClaim>>>(
            find.byType(
              MasterDataTableView<FormDraftCategoryRow<ExpenseClaim>>,
            ),
          );
      expect(
        [...table.unpagedItems, ...table.items].map((row) => row.draft?.id),
        ['claim-local'],
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stock draft category is isolated by document type instead of shared stockDocument bucket',
    (tester) async {
      await _pump(
        tester,
        const StockDocListPage(
          docType: StockDocType.otherIn,
          initialStatus: 'draft',
        ),
        '/warehouse/OTHER_IN',
        [
          _draft(
            'in-local',
            BadgeModule.warehouse,
            '/warehouse/OTHER_IN/new',
            kind: 'stockDocument',
          ),
          _draft(
            'out-local',
            BadgeModule.warehouse,
            '/warehouse/OTHER_OUT/new',
            kind: 'stockDocument',
          ),
          _draft(
            'count-local',
            BadgeModule.warehouse,
            '/warehouse/CHECK/new',
            kind: 'stockCheck',
          ),
        ],
      );
      final table = tester
          .widget<MasterDataTableView<FormDraftCategoryRow<StockDocListItem>>>(
            find.byType(
              MasterDataTableView<FormDraftCategoryRow<StockDocListItem>>,
            ),
          );
      expect(
        [...table.unpagedItems, ...table.items].map((row) => row.draft?.id),
        ['in-local'],
      );
      expect(find.byType(FormDraftsPanel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inbound task input appears in directional draft category and never mixes outbound or manual docs',
    (tester) async {
      await _pump(
        tester,
        const WarehouseInboundTaskCenterPage(),
        '/warehouse/tasks/inbound',
        [
          _draft(
            'arrival-local',
            BadgeModule.warehouse,
            '/warehouse/inbound/receipts/new',
          ),
          _draft(
            'outbound-local',
            BadgeModule.warehouse,
            '/warehouse/subcontract-outbound/issue-1',
          ),
          _draft(
            'stock-local',
            BadgeModule.warehouse,
            '/warehouse/OTHER_IN/new',
            kind: 'stockDocument',
          ),
        ],
      );
      // 2026-10-04 起红数「草稿」段进页面自动选中：方向性草稿分类随挂载即渲染
      // （选中后内容区还有第二条工具条，取顶部分类栏）。
      expect(find.byType(FormDraftCategoryList), findsOneWidget);
      final toolbar = tester.widget<UtenFilterToolbar<String>>(
        find.byType(UtenFilterToolbar<String>).first,
      );
      expect(
        toolbar.segments
            .singleWhere((segment) => segment.value == 'drafts')
            .count,
        1,
      );
      toolbar.onSelectionChanged!('drafts');
      await tester.pumpAndSettle();
      expect(find.byType(WarehouseFormDraftCategory), findsOneWidget);
      expect(find.textContaining('arrival-local'), findsWidgets);
      expect(find.textContaining('outbound-local'), findsNothing);
      expect(find.textContaining('stock-local'), findsNothing);
      expect(find.byType(FormDraftsPanel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget page,
  String location,
  List<FormDraft> drafts, {
  bool failFinance = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: location,
    routes: [GoRoute(path: location, builder: (_, _) => page)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_Api(failFinance: failFinance)),
        sharedPreferencesProvider.overrideWithValue(prefs),
        sessionProvider.overrideWith(_Session.new),
        formDraftsProvider.overrideWith(() => _Drafts(drafts)),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeExpenseView,
          Perm.financeExpenseCreate,
          Perm.stockDocView,
          Perm.stockDocCreate,
          Perm.warehouseInboundView,
          Perm.expenseApply,
        }),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api({this.failFinance = false}) : super(Dio());
  final bool failFinance;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/documents/status-counts') {
      return {
        'DRAFT': query?['kind'] == 'financeExpense' ? 1 : 0,
        'APPROVED': 0,
        'REVERSED': 0,
      };
    }
    if (path.endsWith('type-counts')) return {'PURCHASE': 0, 'SUBCONTRACT': 0};
    if (path.endsWith('/facets')) return {};
    if (failFinance && path == '/finance/expenses') {
      throw NetworkException('offline');
    }
    final rows = <Map<String, dynamic>>[
      if (path == '/finance/expenses')
        {
          'id': 'formal-1',
          'billNo': 'FY-001',
          'billDate': '2026-09-26',
          'status': query?['status'] ?? 0,
        },
    ];
    return {
      'items': rows,
      'page': 1,
      'size': 20,
      'total': rows.length,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}
