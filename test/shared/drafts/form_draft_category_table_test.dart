import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.initial);
  final List<FormDraft> initial;
  final deleted = <String>[];
  @override
  List<FormDraft> build() => initial;
  @override
  Future<void> delete(String id, {String? expectedRevision}) async {
    deleted.add(id);
    state = state.where((d) => d.id != id).toList();
  }
}

class _Record {
  const _Record(this.id, this.number);
  final String id, number;
}

FormDraft _draft(String id, {String kind = 'salesOrder', String? createdId}) =>
    FormDraft(
      id: id,
      title: '新建订货单',
      module: BadgeModule.sales,
      route: '/sales/orders/new?returnTo=%2Fsales%2Ftasks',
      permission: 'sales_order:create',
      draftKind: kind,
      updatedAt: DateTime(2026, 9, 27),
      data: {
        'clientId': 'client-a',
        'text': {'remark': '半途保存'},
        'createdDocId': createdId,
      },
    );
typedef _Union = FormDraftCategoryRow<_Record>;
const _scope = FormDraftCategoryScope(kind: 'salesOrder');

void main() {
  testWidgets(
    'continuous pages keep typed business rows and live local drafts',
    (tester) async {
      final drafts = _Drafts([_draft('local')]);
      final rows = MasterDataTableRowsController<_Record>();
      var page = 1;
      final selectedRecords = <_Record>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftsProvider.overrideWith(() => drafts)],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) => FormDraftCategoryTable<_Record>(
                  scope: _scope,
                  table: MasterDataTableView<_Record>(
                    columns: [
                      MasterColumnDef(
                        key: 'billNo',
                        label: '单号',
                        width: 200,
                        value: (r) => r.number,
                      ),
                    ],
                    items: page == 1
                        ? const [_Record('one', 'XD-1')]
                        : const [_Record('two', 'XD-2')],
                    rowsController: rows,
                    selectable: true,
                    idOf: (r) => r.id,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onSelectedIdsChanged: (ids) {
                      selectedRecords.clear();
                      selectedRecords.addAll(
                        rows.items.where((row) => ids.contains(row.id)),
                      );
                    },
                    currentPage: page,
                    totalPages: 2,
                    paginationScope: 'same-query',
                    onPageChange: (next) => update(() => page = next),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await rows.loadNextPage();
      await tester.pumpAndSettle();
      expect(page, 2);
      expect(rows.items.map((row) => row.id), ['one', 'two']);
      expect(find.text('未提交草稿'), findsOneWidget);
      final table = tester.widget<MasterDataTableView<_Union>>(
        find.byType(MasterDataTableView<_Union>),
      );
      table.onSelectedIdsChanged!({'one', 'two', 'form-draft:local'});
      await tester.pump();
      expect(selectedRecords.map((row) => row.id), ['one', 'two']);
      await drafts.delete('local');
      await tester.pumpAndSettle();
      expect(find.text('未提交草稿'), findsNothing);
      expect(rows.items.map((row) => row.id), ['one', 'two']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty standalone draft category opens without table assertions',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftsProvider.overrideWith(() => _Drafts([]))],
          child: const MaterialApp(
            home: Scaffold(body: FormDraftCategoryList(scope: _scope)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'standalone category keeps a confirmed workflow available to finish',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            formDraftsProvider.overrideWith(
              () => _Drafts([_draft('finish', createdId: 'server-1')]),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: FormDraftCategoryList(scope: _scope)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新建订货单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('filter aliases preserve header and per-row party identity', () {
    final row = _draft('one');
    expect(formDraftColumnRawValues(row, 'client'), {'client-a'});
    final multi = FormDraft(
      id: 'multi',
      title: '订单',
      module: BadgeModule.purchase,
      route: '/purchase/orders/new',
      permission: 'purchase_order:create',
      updatedAt: DateTime(2026),
      data: {
        'rows': [
          {
            'supplierId': 'first',
            'terms': {
              'currencyId': 'usd',
              'priceContext': {
                'supplierId': 'old-supplier',
                'currencyId': 'old-currency',
              },
            },
          },
          {'supplierId': 'second'},
        ],
      },
    );
    expect(formDraftColumnRawValues(multi, 'supplier'), {'first', 'second'});
    expect(formDraftColumnRawValues(multi, 'currency'), {'usd'});
  });

  testWidgets(
    'offline local rows remain visible and custom row-selection works',
    (tester) async {
      var formalSelections = 0;
      var retries = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            formDraftsProvider.overrideWith(() => _Drafts([_draft('local')])),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FormDraftCategoryTable<_Record>(
                scope: _scope,
                table: MasterDataTableView<_Record>(
                  columns: [
                    MasterColumnDef(
                      key: 'billNo',
                      label: '单号',
                      width: 180,
                      value: (r) => r.number,
                    ),
                    MasterColumnDef(
                      key: 'client',
                      label: '客户',
                      width: 180,
                      value: (_) => '甲客户',
                    ),
                  ],
                  items: const [_Record('server-1', '旧缓存XD')],
                  facets: const {
                    'client': [
                      MasterFacetBucket(
                        value: 'client-a',
                        count: 1,
                        label: '甲客户',
                      ),
                    ],
                  },
                  nullCounts: const {},
                  filters: const {'client': 'client-a'},
                  onFilterChanged: (_, _) {},
                  error: '网络离线',
                  onRetry: () => retries++,
                  selectable: true,
                  idOf: (r) => r.id,
                  onRowSelectionChanged: (_, _) => formalSelections++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var table = tester.widget<MasterDataTableView<_Union>>(
        find.byType(MasterDataTableView<_Union>),
      );
      expect(table.items, hasLength(1));
      expect(table.columns.last.value(table.items.single), '甲客户');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('form-draft-row-local')),
          matching: find.text('甲客户'),
        ),
        findsOneWidget,
      );
      expect(find.text('旧缓存XD'), findsNothing);
      table.onRowSelectionChanged!(table.items.single, true);
      await tester.pump();
      table = tester.widget<MasterDataTableView<_Union>>(
        find.byType(MasterDataTableView<_Union>),
      );
      expect(table.selectedIds, contains('form-draft:local'));
      expect(formalSelections, 0);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retries, 1);
    },
  );
  test(
    'category counts exclude already-created documents and keep kinds isolated',
    () {
      final container = ProviderContainer(
        overrides: [
          formDraftsProvider.overrideWith(
            () => _Drafts([
              _draft('new'),
              _draft('created', createdId: 'server-1'),
              _draft('quote', kind: 'salesQuote'),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(formDraftCategoryProvider(_scope)), hasLength(2));
      expect(container.read(formDraftCategoryCountProvider(_scope)), 1);
      expect(formDraftConfirmedIds(_draft('created', createdId: 'server-1')), {
        'server-1',
      });
    },
  );

  testWidgets(
    'one category table merges rows; local resume delete and selection never call business actions',
    (tester) async {
      final drafts = _Drafts([
        _draft('local'),
        _draft('other', kind: 'salesQuote'),
      ]);
      var openedFormal = 0;
      var deletedFormal = 0;
      var remoteSelection = <String>{};
      final router = GoRouter(
        initialLocation: '/list',
        routes: [
          GoRoute(
            path: '/list',
            builder: (_, _) => Scaffold(
              body: FormDraftCategoryTable<_Record>(
                scope: _scope,
                formalId: (r) => r.id,
                table: MasterDataTableView<_Record>(
                  columns: [
                    MasterColumnDef(
                      key: 'billNo',
                      label: '单号',
                      width: 200,
                      value: (r) => r.number,
                    ),
                    MasterColumnDef(
                      key: 'remark',
                      label: '备注',
                      width: 240,
                      value: (_) => '业务单据',
                    ),
                  ],
                  items: const [
                    _Record('server-1', 'XD-1'),
                    _Record('server-2', 'XD-2'),
                  ],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  selectable: true,
                  idOf: (r) => r.id,
                  onSelectedIdsChanged: (ids) => remoteSelection = ids,
                  onRowTap: (_) => openedFormal++,
                  rowMenuBuilder: (_) => [
                    UtenMenuItem(label: '删除业务草稿', onTap: () => deletedFormal++),
                  ],
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/sales/orders/new',
            builder: (_, s) =>
                Scaffold(body: Text('恢复 ${s.uri.queryParameters['draftId']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftsProvider.overrideWith(() => drafts)],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var table = tester.widget<MasterDataTableView<_Union>>(
        find.byType(MasterDataTableView<_Union>),
      );
      expect(table.items, hasLength(3));
      expect(table.items.where((r) => r.isLocal).single.draft!.id, 'local');
      table.onSelectedIdsChanged!({'server-1', 'form-draft:local'});
      await tester.pump();
      expect(remoteSelection, {'server-1'});
      table = tester.widget<MasterDataTableView<_Union>>(
        find.byType(MasterDataTableView<_Union>),
      );
      table.onRowTap!(table.items.first);
      await tester.pumpAndSettle();
      expect(find.text('恢复 local'), findsOneWidget);
      expect(openedFormal, 0);
      router.pop();
      await tester.pumpAndSettle();
      table = tester.widget<MasterDataTableView<_Union>>(
        find.byType(MasterDataTableView<_Union>),
      );
      final deletion = table.rowMenuBuilder!(table.items.first)
          .whereType<UtenMenuItem>()
          .last
          .onTap();
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      if (deletion is Future<void>) await deletion;
      expect(drafts.deleted, ['local']);
      expect(deletedFormal, 0);
      expect(find.text('XD-1'), findsOneWidget);
      expect(find.text('XD-2'), findsOneWidget);
      expect(find.text('未提交草稿'), findsNothing);
    },
  );

  testWidgets(
    'known created checkpoint overlays one formal row and adds no duplicate',
    (tester) async {
      final drafts = _Drafts([_draft('local', createdId: 'server-1')]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftsProvider.overrideWith(() => drafts)],
          child: MaterialApp(
            home: Scaffold(
              body: FormDraftCategoryTable<_Record>(
                scope: _scope,
                formalId: (r) => r.id,
                table: MasterDataTableView<_Record>(
                  columns: [
                    MasterColumnDef(
                      key: 'billNo',
                      label: '单号',
                      width: 200,
                      value: (r) => r.number,
                    ),
                  ],
                  items: const [_Record('server-1', 'XD-1')],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<_Union>>(
        find.byType(MasterDataTableView<_Union>),
      );
      expect(table.items, hasLength(1));
      expect(table.items.single.record!.number, 'XD-1');
      expect(table.items.single.draft!.id, 'local');
      expect(find.text('未提交草稿'), findsNothing);
    },
  );

  testWidgets(
    'server column filters apply to local drafts and pages do not repeat them',
    (tester) async {
      final drafts = _Drafts([_draft('local')]);
      Widget app({String? client, int page = 1}) => ProviderScope(
        overrides: [formDraftsProvider.overrideWith(() => drafts)],
        child: MaterialApp(
          home: Scaffold(
            body: FormDraftCategoryTable<_Record>(
              scope: _scope,
              table: MasterDataTableView<_Record>(
                columns: [
                  MasterColumnDef(
                    key: 'billNo',
                    label: '单号',
                    width: 200,
                    value: (r) => r.number,
                  ),
                ],
                items: const [],
                facets: const {},
                nullCounts: const {},
                filters: {'clientId': client},
                onFilterChanged: (_, _) {},
                currentPage: page,
                totalPages: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(client: 'different'));
      await tester.pumpAndSettle();
      expect(find.text('未提交草稿'), findsNothing);
      await tester.pumpWidget(app(client: 'client-a'));
      await tester.pumpAndSettle();
      expect(find.text('未提交草稿'), findsOneWidget);
      await tester.pumpWidget(app(page: 2));
      await tester.pumpAndSettle();
      expect(find.text('未提交草稿'), findsNothing);
    },
  );
}
