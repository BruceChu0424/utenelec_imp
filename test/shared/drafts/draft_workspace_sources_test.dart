import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_table.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../helpers/badge_summary_fixture.dart';

FormDraft _draft(
  String id, {
  String kind = 'financeExpense',
  String? created,
}) => FormDraft(
  id: id,
  title: '新建费用 $id',
  module: BadgeModule.finance,
  route: '/finance/expenses/new',
  permission: '',
  draftKind: kind,
  updatedAt: DateTime(2026, 9, 30),
  data: {'createdDocId': created},
);

const _expense = DraftWorkspaceRow(
  kind: DraftDocKind.financeExpense,
  id: 'formal',
  category: '一般费用单',
  location: '/finance/expenses/formal',
  billNo: 'FY-001',
  deletable: true,
);
const _receipt = DraftWorkspaceRow(
  kind: DraftDocKind.financeReceipt,
  id: 'receipt',
  category: '销售收款单',
  location: '/finance/receipts/receipt',
  billNo: 'SK-001',
  deletable: true,
);

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.drafts);
  final List<FormDraft> drafts;
  final deleted = <(String, String?)>[];
  @override
  List<FormDraft> build() => drafts;
  @override
  Future<void> delete(String id, {String? expectedRevision}) async {
    deleted.add((id, expectedRevision));
    state = state.where((draft) => draft.id != id).toList();
  }
}

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Map<String, String> get supplierEntries => const {'supplier-a': '丰翔'};
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _PurchaseRepository extends PurchaseRepository {
  _PurchaseRepository() : super(ApiClient(Dio()), PurchaseDocType.order);
  final deleted = <String>[];
  void Function()? afterDelete;
  @override
  Future<PagedResult<PurchaseDocListItem>> list({
    int page = 1,
    int size = 20,
    PurchaseDocFilter filter = const PurchaseDocFilter(),
    String? sort,
    String? order,
  }) async {
    final rows = [
      for (final id in ['one', 'two'])
        if (!deleted.contains(id))
          PurchaseDocListItem(id: id, billNo: id, status: 0, totalLocal: 42.0),
    ];
    return PagedResult(
      items: rows,
      page: page,
      size: size,
      total: rows.length,
      totalPages: 1,
    );
  }

  @override
  Future<PurchaseDocDetail> detail(String id) async =>
      PurchaseDocDetail.fromJson({'id': id, 'status': 0, 'makerId': 'maker'});
  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    afterDelete?.call();
    await Future<void>.delayed(Duration.zero);
  }
}

class _SubcontractRepository extends SubcontractRepository {
  _SubcontractRepository() : super(ApiClient(Dio()), SubcontractDocType.order);
  @override
  Future<PagedResult<SubcontractDocListItem>> list({
    int page = 1,
    int size = 20,
    SubcontractDocFilter filter = const SubcontractDocFilter(),
    String? sort,
    String? order,
  }) async => PagedResult(
    items: const [SubcontractDocListItem(id: 'one', status: 0, totalLocal: 42)],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Drafts drafts, {
  bool failReceipt = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'draft-test'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeExpenseView,
          Perm.financeReceiptView,
          Perm.financeExpenseDelete,
          Perm.financeReceiptDelete,
        }),
        formDraftsProvider.overrideWith(() => drafts),
        masterNameServiceProvider.overrideWith((ref) => _Names()),
        fixedBadgeSummaryOverride(),
        draftWorkspaceRowsProvider(
          DraftDocKind.financeExpense,
        ).overrideWith((ref) async => [_expense]),
        draftWorkspaceRowsProvider(DraftDocKind.financeReceipt).overrideWith((
          ref,
        ) async {
          if (failReceipt) throw NetworkException('offline');
          return [_receipt];
        }),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: DraftWorkspaceTable(
            kinds: [DraftDocKind.financeExpense, DraftDocKind.financeReceipt],
            localScope: FormDraftCategoryScope(module: BadgeModule.finance),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MasterDataTableView<DraftWorkspaceRow> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<DraftWorkspaceRow>));

void main() {
  testWidgets(
    'local supplier IDs resolve through the shared dictionary and remain searchable',
    (tester) async {
      final draft = FormDraft(
        id: 'suppliers',
        title: '采购录入',
        module: BadgeModule.finance,
        route: '/purchase/orders/new',
        permission: '',
        draftKind: 'purchaseOrder',
        updatedAt: DateTime(2026, 9, 30),
        data: const {
          'rows': [
            {'supplierId': 'supplier-a'},
            {'supplierId': 'not-cached'},
          ],
        },
      );
      await _pump(tester, _Drafts([draft]));
      expect(_table(tester).items.first.party, '丰翔、已选择');
      tester
          .widget<UtenFilterToolbar<String>>(
            find.byType(UtenFilterToolbar<String>),
          )
          .onSearchChanged!('丰翔');
      await tester.pumpAndSettle();
      expect(_table(tester).items.map((row) => row.key), ['local:suppliers']);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'commercial amounts remain masked without each exact price permission',
    () async {
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'draft-test'),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.purchaseOrderView,
            Perm.subcontractOrderView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          sessionSnapshotProvider.overrideWith(_Snapshot.new),
          masterNameServiceProvider.overrideWith((ref) => _Names()),
          purchaseRepositoryProvider(
            PurchaseDocType.order,
          ).overrideWithValue(_PurchaseRepository()),
          subcontractRepositoryProvider(
            SubcontractDocType.order,
          ).overrideWithValue(_SubcontractRepository()),
        ],
      );
      addTearDown(container.dispose);
      final purchase = await container.read(
        draftWorkspaceRowsProvider(DraftDocKind.purchaseOrder).future,
      );
      final subcontract = await container.read(
        draftWorkspaceRowsProvider(DraftDocKind.subcontractOrder).future,
      );
      expect(purchase.map((row) => row.amount), ['***', '***']);
      expect(subcontract.single.amount, '***');
    },
  );

  testWidgets(
    'server write revisions do not interrupt a selected batch or checkpoint cleanup',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = _PurchaseRepository();
      final checkpoint = _draft(
        'checkpoint',
        kind: 'purchaseOrder',
        created: 'one',
      );
      final drafts = _Drafts([checkpoint]);
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'draft-test'),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.purchaseOrderView,
            Perm.purchaseOrderDelete,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          sessionSnapshotProvider.overrideWith(_Snapshot.new),
          masterNameServiceProvider.overrideWith((ref) => _Names()),
          purchaseRepositoryProvider(
            PurchaseDocType.order,
          ).overrideWithValue(repo),
          documentScopeCapabilityProvider(
            DocumentDataScope.purchase,
          ).overrideWith(
            (ref) async => const DocumentScopeCapability(
              scope: 'purchase',
              writeAll: true,
              writableOwnerIds: {},
            ),
          ),
          formDraftsProvider.overrideWith(() => drafts),
          fixedBadgeSummaryOverride(),
        ],
      );
      addTearDown(container.dispose);
      repo.afterDelete = () {
        container.read(dataWriteRevisionProvider.notifier).state++;
        // Another mounted workspace can refresh this shared source too.
        container.invalidate(
          draftWorkspaceRowsProvider(DraftDocKind.purchaseOrder),
        );
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: DraftWorkspaceTable(
                kinds: [DraftDocKind.purchaseOrder],
                localScope: FormDraftCategoryScope(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_table(tester).items.length, 2);
      _table(tester).onSelectedIdsChanged!({
        'purchaseOrder:one',
        'purchaseOrder:two',
      });
      await tester.pump();
      await tester.tap(find.text('删除所选草稿 (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(repo.deleted, ['one', 'two']);
      expect(drafts.deleted, [('checkpoint', checkpoint.revision)]);
      expect(_table(tester).items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'all pages are read even when the first server page is capped',
    () async {
      final requested = <int>[];
      final rows = await loadAllDraftPages<int>((page) async {
        requested.add(page);
        return PagedResult(
          items: [page],
          page: page,
          size: 1,
          total: 3,
          totalPages: 3,
        );
      });
      expect(rows, [1, 2, 3]);
      expect(requested, [1, 2, 3]);
    },
  );

  test(
    'an empty intermediate page is not silently treated as the full result',
    () async {
      await expectLater(
        loadAllDraftPages<int>(
          (page) async => PagedResult(
            items: page == 1 ? [1] : [],
            page: page,
            size: 1,
            total: 3,
            totalPages: 3,
          ),
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'a wrong page response is rejected instead of repeating a page forever',
    () async {
      await expectLater(
        loadAllDraftPages<int>(
          (page) async => const PagedResult(
            items: [1],
            page: 1,
            size: 1,
            total: 2,
            totalPages: 2,
          ),
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'confirmed checkpoints overlay kind plus id; failed sources keep recovery',
    () {
      final checkpoint = _draft('checkpoint', created: 'formal');
      const differentKind = DraftWorkspaceRow(
        kind: DraftDocKind.financeReceipt,
        id: 'formal',
        category: '销售收款单',
        location: '/finance/receipts/formal',
      );
      final merged = mergeDraftWorkspaceRows(
        [_expense, differentKind],
        [checkpoint],
      );
      expect(merged.length, 2);
      expect(merged.first.local?.id, 'checkpoint');
      expect(merged.last.local, isNull);
      expect(
        mergeDraftWorkspaceRows([], [checkpoint]).single.local?.id,
        'checkpoint',
      );
    },
  );

  test('stock aggregate matches checkpoints counted by a stock slice', () {
    final checkpoint = _draft(
      'count-checkpoint',
      kind: 'stockCheck',
      created: 'check-1',
    );
    const formal = DraftWorkspaceRow(
      kind: DraftDocKind.stockDocument,
      id: 'check-1',
      category: '盘点',
      location: '/warehouse/CHECK/check-1',
      stockType: StockDocType.check,
    );
    final rows = mergeDraftWorkspaceRows([formal], [checkpoint]);
    expect(rows.length, 1);
    expect(rows.single.local?.id, checkpoint.id);
  });

  testWidgets(
    'category header clears prior selection before changing visible rows',
    (tester) async {
      await _pump(tester, _Drafts([_draft('local')]));
      var table = _table(tester);
      expect(table.columns.first.key, 'category');
      table.onSelectedIdsChanged!({
        'financeExpense:formal',
        'financeReceipt:receipt',
        'local:local',
      });
      await tester.pump();
      expect(_table(tester).selectedIds.length, 3);
      table = _table(tester);
      table.onFilterChanged('category', '销售收款单');
      await tester.pumpAndSettle();
      table = _table(tester);
      expect(table.items.map((row) => row.key), ['financeReceipt:receipt']);
      expect(table.selectedIds, isEmpty);
      expect(find.text('删除所选草稿 (0)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial source error retains local and other formal rows', (
    tester,
  ) async {
    await _pump(tester, _Drafts([_draft('local')]), failReceipt: true);
    expect(_table(tester).items.map((row) => row.key), [
      'local:local',
      'financeExpense:formal',
    ]);
    expect(find.textContaining('销售收款单加载失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local bulk delete uses store revision and never a formal repository',
    (tester) async {
      final local = _draft('local');
      final drafts = _Drafts([local]);
      await _pump(tester, drafts);
      _table(tester).onSelectedIdsChanged!({'local:local'});
      await tester.pump();
      final button = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '删除所选草稿 (1)'),
      );
      button.onPressed!();
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(drafts.deleted, [('local', local.revision)]);
      expect(_table(tester).items.map((row) => row.key), [
        'financeExpense:formal',
        'financeReceipt:receipt',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
