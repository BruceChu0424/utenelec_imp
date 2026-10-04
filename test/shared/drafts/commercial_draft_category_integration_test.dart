import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_draft_task_category.dart';
import 'package:uten_imp/features/sales/config/sales_doc_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_page_factory.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_table.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.drafts);
  final List<FormDraft> drafts;
  @override
  List<FormDraft> build() => drafts;
}

class _Api extends ApiClient {
  _Api({this.queueOffline = false}) : super(Dio());
  final bool queueOffline;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (queueOffline && path.startsWith('/operations/workbench/')) {
      throw StateError('simulated task queue offline');
    }
    return {
      'items': [
        for (var i = 1; i <= 2; i++)
          {
            'id': 'formal-$i',
            'billNo': 'FORMAL-$i',
            'billDate': '2026-09-26',
            'status': 0,
            'writable': true,
          },
      ],
      'page': 1,
      'size': 50,
      'total': 2,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

void main() {
  for (final subcontract in [false, true]) {
    testWidgets(
      '${subcontract ? 'subcontract' : 'purchase'} center draft classification stays reachable when queue is offline',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final kind = subcontract ? 'subcontractOrder' : 'purchaseOrder';
        final local = FormDraft(
          id: 'local-center',
          title: '未完成订货',
          module: subcontract ? BadgeModule.subcontract : BadgeModule.purchase,
          draftKind: kind,
          route: subcontract
              ? '/subcontract/orders/new'
              : '/purchase/orders/new',
          permission: '',
          updatedAt: DateTime.now(),
          data: const {'billDate': '2026-09-26'},
        );
        final master = FormDraft(
          id: 'supplier-draft',
          title: '待补供应商资料',
          module: local.module,
          route: '/basicinfo/supplier/new',
          permission: '',
          updatedAt: DateTime.now(),
          data: const {},
        );
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => subcontract
                  ? const SubcontractDecompositionPage()
                  : OperationsWorkbenchPage(
                      department: OperationsWorkbenchDepartment.purchase,
                      draftCategoryBuilder:
                          (_, {required search, required externalHeader}) =>
                              PurchaseDraftTaskCategory(
                                search: search,
                                externalHeader: externalHeader,
                              ),
                    ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(_Api(queueOffline: true)),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'draft-reviewer'),
              ),
              sharedPreferencesProvider.overrideWithValue(prefs),
              currentPermissionsProvider.overrideWithValue({
                subcontract
                    ? Perm.subcontractOrderView
                    : Perm.purchaseOrderView,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              formDraftsProvider.overrideWith(() => _Drafts([local, master])),
              documentStatusCountsProvider.overrideWith(
                (ref, scope) async => {'DRAFT': 2},
              ),
              fixedBadgeSummaryOverride(
                badgeSummaryFixture(facts: {'drafts.$kind': 2}),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('未完成草稿'), findsNothing);
        expect(find.text('未提交草稿'), findsNothing);
        await tester.tap(find.text('草稿'));
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<DraftWorkspaceRow>,
          ),
        );
        expect(table.items, hasLength(4));
        expect(
          table.items
              .where((row) => row.local != null)
              .map((row) => row.local!.id),
          unorderedEquals(['local-center', 'supplier-draft']),
        );
        expect(table.columns.first.key, 'category');
        expect(table.facets['category'], hasLength(2));
        expect(find.byType(TextField), findsOneWidget);
        final searchToolbar = tester.widget<UtenFilterToolbar<dynamic>>(
          find.byWidgetPredicate(
            (widget) =>
                widget is UtenFilterToolbar<dynamic> &&
                widget.onSearchChanged != null,
          ),
        );
        expect(find.text('资料草稿'), findsNothing);
        expect(find.text('草稿'), findsOneWidget);
        expect(
          find.byKey(
            Key(
              '${subcontract ? 'subcontract' : 'purchase'}-draft-document-types',
            ),
          ),
          findsNothing,
        );

        table.onSelectedIdsChanged!({'local:local-center'});
        await tester.pumpAndSettle();
        final selectedTable = tester
            .widget<MasterDataTableView<DraftWorkspaceRow>>(
              find.byWidgetPredicate(
                (w) => w is MasterDataTableView<DraftWorkspaceRow>,
              ),
            );
        expect(selectedTable.selectedIds, isNotEmpty);
        selectedTable.onFilterChanged(
          'category',
          selectedTable.items
              .firstWhere((row) => row.id == 'local-center')
              .category,
        );
        await tester.pumpAndSettle();
        final filteredTable = tester
            .widget<MasterDataTableView<DraftWorkspaceRow>>(
              find.byWidgetPredicate(
                (w) => w is MasterDataTableView<DraftWorkspaceRow>,
              ),
            );
        expect(filteredTable.items, hasLength(3));
        expect(filteredTable.selectedIds, isEmpty);
        filteredTable.onFilterChanged('category', null);
        await tester.pumpAndSettle();

        // The host search must rebuild the draft table even when its task
        // repository is offline; a second embedded search used to mask this.
        searchToolbar.onSearchChanged!('FORMAL-1');
        await tester.pumpAndSettle(const Duration(milliseconds: 400));
        final searchedTable = tester
            .widget<MasterDataTableView<DraftWorkspaceRow>>(
              find.byWidgetPredicate(
                (w) => w is MasterDataTableView<DraftWorkspaceRow>,
              ),
            );
        expect(searchedTable.items.single.billNo, 'FORMAL-1');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  final cases =
      <
        ({
          String label,
          String kind,
          String route,
          BadgeModule module,
          String viewPerm,
          Widget Function() page,
        })
      >[
        for (final type in [
          SalesDocType.order,
          SalesDocType.quote,
          SalesDocType.shipment,
          SalesDocType.customerShipment,
          SalesDocType.returnDoc,
        ])
          (
            label: 'sales ${type.name}',
            kind: type == SalesDocType.customerShipment
                ? 'salesShipment'
                : SalesDocConfig.by(type).draftKind!.name,
            route: '/sales/${type.pathSegment}/new',
            module: BadgeModule.sales,
            viewPerm: SalesDocConfig.by(type).listPerm,
            page: () => SalesDocListPage(docType: type),
          ),
        for (final type in [
          PurchaseDocType.order,
          PurchaseDocType.receipt,
          PurchaseDocType.returnDoc,
        ])
          (
            label: 'purchase ${type.name}',
            kind: PurchaseDocConfig.by(type).draftKind!.name,
            route: '/purchase/${type.pathSegment}/new',
            module: BadgeModule.purchase,
            viewPerm: PurchaseDocConfig.by(type).listPerm,
            page: () => PurchaseDocListPage(docType: type),
          ),
        for (final type in [
          SubcontractDocType.order,
          SubcontractDocType.returnDoc,
          SubcontractDocType.materialReturn,
          SubcontractDocType.waste,
        ])
          (
            label: 'subcontract ${type.name}',
            kind: SubcontractDocConfig.by(type).draftKind!.name,
            route: '/subcontract/${type.pathSegment}/new',
            module: BadgeModule.subcontract,
            viewPerm: SubcontractDocConfig.by(type).listPerm,
            page: () => SubcontractPageFactory.list(type),
          ),
      ];
  for (final item in cases) {
    testWidgets(
      '${item.label} merges only its local draft into selected business draft category',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        FormDraft draft(String id, String kind, String route) => FormDraft(
          id: id,
          title: '未填完${item.label}',
          module: item.module,
          draftKind: route.contains('customer-shipments') ? null : kind,
          route: route,
          permission: '',
          updatedAt: DateTime.now(),
          data: const {
            'billDate': '2026-09-26',
            'text': {'remark': '需要继续填写'},
          },
        );
        final local = draft('local-1', item.kind, item.route);
        final unrelated = draft(
          'wrong-category',
          item.route.contains('customer-shipments')
              ? item.kind
              : 'unrelatedKind',
          '/sales/shipments/new',
        );
        final router = GoRouter(
          routes: [GoRoute(path: '/', builder: (_, _) => item.page())],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(_Api()),
              sharedPreferencesProvider.overrideWithValue(prefs),
              currentPermissionsProvider.overrideWithValue({item.viewPerm}),
              isSuperAdminProvider.overrideWithValue(false),
              formDraftsProvider.overrideWith(
                () => _Drafts([local, unrelated]),
              ),
              documentStatusCountsProvider.overrideWith(
                (ref, scope) async => {'DRAFT': 2},
              ),
              fixedBadgeSummaryOverride(
                badgeSummaryFixture(facts: {'drafts.${item.kind}': 2}),
              ),
            ],
            // 报价列表分段文字走 arb(ADR-134)，与真实 App 一样挂本地化代理。
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('未完成草稿'), findsNothing);
        // 2026-10-04 起红数「草稿」段进页面自动选中：草稿分类内容随挂载即渲染
        // （原「未提交草稿」分类在未选段时不可见的断言随口径退役）。
        final badge = tester.widget<UtenSegmentBadgeLabel>(
          find.byWidgetPredicate(
            (widget) => widget is UtenSegmentBadgeLabel && widget.label == '草稿',
          ),
        );
        expect(badge.count, 3);
        final table = tester
            .widget<MasterDataTableView<FormDraftCategoryRow<Object>>>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is MasterDataTableView<FormDraftCategoryRow<Object>>,
              ),
            );
        final visibleRows = [...table.unpagedItems, ...table.items];
        expect(visibleRows, hasLength(3));
        expect(
          visibleRows.where((row) => row.isLocal).single.draft!.id,
          'local-1',
        );
        expect(visibleRows.where((row) => !row.isLocal), hasLength(2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
