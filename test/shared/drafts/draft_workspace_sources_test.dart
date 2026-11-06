import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/server_selection.dart';
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
  Future<void> loadSupplierNames(Iterable<String> ids) async {}
  @override
  String supplier(String? id) => supplierEntries[id] ?? '—';
  @override
  Map<String, String> get supplierEntries => const {'supplier-a': '丰翔'};
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _PurchaseRepository extends PurchaseRepository {
  _PurchaseRepository({this.exactAmount})
    : super(ApiClient(Dio()), PurchaseDocType.order);
  final String? exactAmount;
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
          PurchaseDocListItem(
            id: id,
            billNo: id,
            status: 0,
            totalLocal: 42.0,
            totalLocalText: exactAmount,
          ),
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

class _ProgressivePurchaseRepository extends _PurchaseRepository {
  _ProgressivePurchaseRepository({this.firstId = 'first'});
  final String firstId;
  final String firstLabel = '首批采购草稿';
  int detailStatus = 0;
  final detailReads = <String>[];
  @override
  Future<PurchaseDocDetail> detail(String id) async {
    detailReads.add(id);
    return PurchaseDocDetail.fromJson({
      'id': id,
      'status': detailStatus,
      'makerId': 'maker',
    });
  }

  final later = Completer<PagedResult<PurchaseDocListItem>>();
  final requested = <int>[];

  @override
  Future<PagedResult<PurchaseDocListItem>> list({
    int page = 1,
    int size = 20,
    PurchaseDocFilter filter = const PurchaseDocFilter(),
    String? sort,
    String? order,
  }) async {
    requested.add(page);
    if (page == 1) {
      return PagedResult(
        items: [
          PurchaseDocListItem(id: firstId, billNo: firstLabel, status: 0),
        ],
        page: 1,
        size: 1,
        total: 2,
        totalPages: 2,
      );
    }
    return later.future;
  }
}

class _SubcontractRepository extends SubcontractRepository {
  _SubcontractRepository({this.exactAmount})
    : super(ApiClient(Dio()), SubcontractDocType.order);
  final String? exactAmount;
  @override
  Future<PagedResult<SubcontractDocListItem>> list({
    int page = 1,
    int size = 20,
    SubcontractDocFilter filter = const SubcontractDocFilter(),
    String? sort,
    String? order,
  }) async => PagedResult(
    items: [
      SubcontractDocListItem(
        id: 'one',
        status: 0,
        totalLocal: 42,
        totalLocalText: exactAmount,
      ),
    ],
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
        draftWorkspaceReadProvider(
          DraftDocKind.financeExpense,
        ).overrideWith((ref) => DraftWorkspaceRead.fromRows([_expense])),
        draftWorkspaceReadProvider(DraftDocKind.financeReceipt).overrideWith((
          ref,
        ) {
          final owner = DraftWorkspaceRead<DraftWorkspaceRow>((read) async {
            if (failReceipt) throw NetworkException('offline');
            read.addRows([_receipt]);
          });
          owner.start();
          ref.onDispose(owner.dispose);
          return owner;
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

Future<List<T>> _readAllDraftPages<T>(
  Future<PagedResult<T>> Function(int) fetch,
) async {
  final owner = DraftWorkspaceRead<T>(
    (read) => read.loadPages(fetch, (rows) async => rows),
  );
  owner.start();
  try {
    return await owner.completion;
  } finally {
    owner.dispose();
  }
}

void main() {
  for (final failLater in [false, true]) {
    testWidgets(
      'a checkpoint whose formal row is on a later ${failLater ? 'failed' : 'pending'} batch cannot be discarded as a local-only row',
      (tester) async {
        final repo = _ProgressivePurchaseRepository()..detailStatus = 1;
        final checkpoint = _draft(
          'checkpoint',
          kind: 'purchaseOrder',
          created: 'later',
        );
        final drafts = _Drafts([checkpoint]);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'draft-progress'),
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.purchaseOrderView,
                Perm.purchaseOrderDelete,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              sessionSnapshotProvider.overrideWith(_Snapshot.new),
              documentScopeCapabilityProvider(
                DocumentDataScope.purchase,
              ).overrideWith(
                (ref) async => const DocumentScopeCapability(
                  scope: 'purchase',
                  writeAll: true,
                  writableOwnerIds: {},
                ),
              ),
              masterNameServiceProvider.overrideWith((ref) => _Names()),
              purchaseRepositoryProvider(
                PurchaseDocType.order,
              ).overrideWithValue(repo),
              formDraftsProvider.overrideWith(() => drafts),
              fixedBadgeSummaryOverride(),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: DraftWorkspaceTable(
                  kinds: [DraftDocKind.purchaseOrder],
                  localScope: FormDraftCategoryScope(
                    module: BadgeModule.finance,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final local = _table(
          tester,
        ).items.singleWhere((row) => row.local != null);
        expect(local.kind, isNull);
        expect(_table(tester).idOf!(local), isNull);
        expect(_table(tester).onSelectedIdsChanged, isNull);
        expect(drafts.deleted, isEmpty);
        expect(repo.deleted, isEmpty);
        if (failLater) {
          repo.later.completeError(NetworkException('offline'));
          await tester.pumpAndSettle();
          expect(_table(tester).idOf!(local), isNull);
          expect(_table(tester).onSelectedIdsChanged, isNull);
          expect(drafts.state.single.id, checkpoint.id);
          expect(drafts.deleted, isEmpty);
          expect(repo.deleted, isEmpty);
        } else {
          repo.later.complete(
            const PagedResult(
              items: [
                PurchaseDocListItem(id: 'later', billNo: '后页正式草稿', status: 0),
              ],
              page: 2,
              size: 1,
              total: 2,
              totalPages: 2,
            ),
          );
          await tester.pumpAndSettle();
          final formal = _table(
            tester,
          ).items.singleWhere((row) => row.id == 'later');
          expect(formal.kind, DraftDocKind.purchaseOrder);
          expect(formal.local, same(checkpoint));
          _table(tester).onSelectedIdsChanged!({formal.key});
          await tester.pumpAndSettle();
          await tester.tap(find.text('删除所选草稿 (1)'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认删除'));
          await tester.pumpAndSettle();
          expect(repo.detailReads, ['later']);
          expect(repo.deleted, isEmpty);
          expect(
            drafts.deleted,
            isEmpty,
            reason:
                'The formal status changed: its existing authoritative guard runs before local CAS discard.',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'an identity change retires the old owner and its pending later page',
    () async {
      var identity = const AuthenticatedScope(userId: 'reader-a');
      final signal = Provider<AuthenticatedScope>((ref) => identity);
      final first = _ProgressivePurchaseRepository(firstId: 'a-first');
      final second = _ProgressivePurchaseRepository(firstId: 'b-first');
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(signal)),
          currentPermissionsProvider.overrideWithValue({
            Perm.purchaseOrderView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          sessionSnapshotProvider.overrideWith(_Snapshot.new),
          masterNameServiceProvider.overrideWith((ref) => _Names()),
          purchaseRepositoryProvider(PurchaseDocType.order).overrideWith(
            (ref) => ref.watch(authenticatedScopeProvider)?.userId == 'reader-a'
                ? first
                : second,
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(
        draftWorkspaceSnapshotProvider(DraftDocKind.purchaseOrder),
        (_, _) {},
      );
      final old = container.read(
        draftWorkspaceReadProvider(DraftDocKind.purchaseOrder),
      );
      await old.firstPage;
      expect(old.snapshot.rows.single.id, 'a-first');
      identity = const AuthenticatedScope(userId: 'reader-b');
      container.invalidate(signal);
      await container.pump();
      final current = container.read(
        draftWorkspaceReadProvider(DraftDocKind.purchaseOrder),
      );
      await current.firstPage;
      expect(old.current, isFalse);
      expect(current.snapshot.rows.single.id, 'b-first');
      first.later.complete(
        const PagedResult(
          items: [
            PurchaseDocListItem(id: 'a-late', billNo: '旧身份后页', status: 0),
          ],
          page: 2,
          size: 1,
          total: 2,
          totalPages: 2,
        ),
      );
      await container.pump();
      expect(current.snapshot.rows.map((row) => row.id), ['b-first']);
      second.later.complete(
        const PagedResult(
          items: [
            PurchaseDocListItem(id: 'b-late', billNo: '当前身份后页', status: 0),
          ],
          page: 2,
          size: 1,
          total: 2,
          totalPages: 2,
        ),
      );
      expect((await current.completion).map((row) => row.id), [
        'b-first',
        'b-late',
      ]);
      expect(first.requested, [1, 2]);
      expect(second.requested, [1, 2]);
    },
  );

  testWidgets(
    'first draft page and local inputs render before complete global search and facets',
    (tester) async {
      final repo = _ProgressivePurchaseRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'draft-progress'),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.purchaseOrderView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
            masterNameServiceProvider.overrideWith((ref) => _Names()),
            purchaseRepositoryProvider(
              PurchaseDocType.order,
            ).overrideWithValue(repo),
            formDraftsProvider.overrideWith(() => _Drafts([_draft('local')])),
            fixedBadgeSummaryOverride(),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DraftWorkspaceTable(
                kinds: [DraftDocKind.purchaseOrder],
                localScope: FormDraftCategoryScope(module: BadgeModule.finance),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        _table(tester).items.map((row) => row.key),
        containsAll(['purchaseOrder:first', 'local:local']),
      );
      expect(_table(tester).facets, isEmpty);
      expect(_table(tester).columns.first.info, contains('后续草稿'));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(DraftWorkspaceTable)),
      );
      var completed = false;
      final completeRows = container.read(
        draftWorkspaceRowsProvider(DraftDocKind.purchaseOrder).future,
      );
      unawaited(
        completeRows.then<void>((_) {
          completed = true;
        }),
      );
      tester
          .widget<UtenFilterToolbar<String>>(
            find.byType(UtenFilterToolbar<String>),
          )
          .onSearchChanged!('后页目标');
      await tester.pump();
      expect(_table(tester).items, isEmpty);
      expect(_table(tester).emptyMessage, '正在检索后续草稿');
      expect(completed, isFalse);

      repo.later.complete(
        const PagedResult(
          items: [PurchaseDocListItem(id: 'later', billNo: '后页目标', status: 0)],
          page: 2,
          size: 1,
          total: 2,
          totalPages: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect((await completeRows).map((row) => row.id), ['first', 'later']);
      expect(_table(tester).items.single.id, 'later');
      expect(_table(tester).facets['category']!.single.count, 1);
      expect(repo.requested, [1, 2]);
      expect(tester.takeException(), isNull);
    },
  );

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
      final purchaseSubscription = container.listen(
        draftWorkspaceRowsProvider(DraftDocKind.purchaseOrder),
        (_, _) {},
      );
      final subcontractSubscription = container.listen(
        draftWorkspaceRowsProvider(DraftDocKind.subcontractOrder),
        (_, _) {},
      );
      addTearDown(purchaseSubscription.close);
      addTearDown(subcontractSubscription.close);
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

  test(
    'draft workspace retains original amount tails across source families',
    () async {
      const large =
          '1234567890123456789012345678901234567890.000000000000000000000007';
      const tiny = '0.000000000000000000000001';
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'draft-exact-test'),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.purchaseOrderView,
            Perm.purchaseOrderPriceView,
            Perm.subcontractOrderView,
            Perm.subcontractOrderPriceView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          sessionSnapshotProvider.overrideWith(_Snapshot.new),
          masterNameServiceProvider.overrideWith((ref) => _Names()),
          purchaseRepositoryProvider(
            PurchaseDocType.order,
          ).overrideWithValue(_PurchaseRepository(exactAmount: large)),
          subcontractRepositoryProvider(
            SubcontractDocType.order,
          ).overrideWithValue(_SubcontractRepository(exactAmount: tiny)),
        ],
      );
      addTearDown(container.dispose);
      final purchaseSubscription = container.listen(
        draftWorkspaceRowsProvider(DraftDocKind.purchaseOrder),
        (_, _) {},
      );
      final subcontractSubscription = container.listen(
        draftWorkspaceRowsProvider(DraftDocKind.subcontractOrder),
        (_, _) {},
      );
      addTearDown(purchaseSubscription.close);
      addTearDown(subcontractSubscription.close);
      final purchase = await container.read(
        draftWorkspaceRowsProvider(DraftDocKind.purchaseOrder).future,
      );
      final subcontract = await container.read(
        draftWorkspaceRowsProvider(DraftDocKind.subcontractOrder).future,
      );
      expect(purchase.map((r) => r.amount), [large, large]);
      expect(subcontract.single.amount, tiny);
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
          // Riverpod 3 的同步挂链会把 apiBaseUrl 连同本地可达性探针一起拉起，
          // 60s 周期定时器在假时钟下走不到销毁点；web: true 不起探针。
          localServerReachableProvider.overrideWith(
            (ref) => LocalServerReachabilityNotifier(null, web: true),
          ),
        ],
      );
      addTearDown(container.dispose);
      repo.afterDelete = () {
        container.read(dataWriteRevisionProvider.notifier).state++;
        // Another mounted workspace can refresh this shared source too.
        container.invalidate(
          draftWorkspaceReadProvider(DraftDocKind.purchaseOrder),
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
      final rows = await _readAllDraftPages<int>((page) async {
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
        _readAllDraftPages<int>(
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
        _readAllDraftPages<int>(
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
    expect(_table(tester).columns.first.info, contains('销售收款单尚未完整读取'));
    expect(find.text('重试'), findsOneWidget);
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
