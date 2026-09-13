import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_stock_batch_outbound_page.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_stock_doc_segment.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_stock_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  Future<void> loadEmployeeNames(Iterable<String?> ids) async {}
  @override
  String employee(String? id) => '仓管员(E01)';
  @override
  String goods(String? id) => '功能件';
  @override
  GoodsDictEntry? goodsInfo(String? id) => const GoodsDictEntry(
    name: '功能件',
    code: 'HV5G001',
    stockPlace: 'MASTER-ONLY',
  );
  @override
  String warehouse(String? id) => '轨道车间';
  @override
  String unit(String? id) => '件';
}

class _Scope implements DocumentScopeCapabilityRepository {
  const _Scope();
  @override
  Future<DocumentScopeCapability> current(DocumentDataScope scope) async =>
      DocumentScopeCapability(
        scope: scope.apiValue,
        writeAll: false,
        writableOwnerIds: const {'me'},
      );
}

class _Repo extends StockDocRepository {
  _Repo(StockDocType type) : super(ApiClient(Dio()), type);
  final statuses = <String, int>{};
  final quantities = <String, double>{};
  final approved = <String>[];
  String? failId;
  StockDocFilter? lastFilter;

  @override
  Future<StockDocDetail> detail(String id) async => StockDocDetail(
    id: id,
    docType: type.code,
    billNo: 'OUT-$id',
    billDate: '2026-09-12',
    workerId: 'worker',
    makerName: '制单员(E02)',
    createdAt: '2026-09-12T01:30:00Z',
    remark: '随单备注-$id',
    status: statuses[id] ?? 0,
    makerId: id == 'foreign' ? 'other-owner' : 'me',
    warehouseId: 'leaf',
    items: [
      StockDocItem(
        id: 'line-$id',
        goodsId: 'goods',
        qty: quantities[id] ?? 0.0001,
        unitId: 'unit',
        place: '33333',
        remark: '明细备注-$id',
      ),
    ],
  );

  @override
  Future<StockDocOutboundReview> review(String id) async =>
      StockDocOutboundReview(
        document: await detail(id),
        reviewToken: '${statuses[id] ?? 0}:${quantities[id] ?? 0.0001}',
      );

  @override
  Future<StockDocDetail> approveReviewed(
    String id, {
    required String expectedReviewToken,
  }) async {
    final current = await review(id);
    if (current.reviewToken != expectedReviewToken) {
      throw ApiException('CONFLICT', '单据已变化，请刷新核对', httpStatus: 409);
    }
    return approve(id);
  }

  @override
  Future<StockDocDetail> approve(String id) async {
    approved.add(id);
    if (id == failId) throw NetworkTimeoutException();
    statuses[id] = 1;
    return detail(id);
  }

  @override
  Future<PagedResult<StockDocListItem>> list({
    int page = 1,
    int size = 20,
    StockDocFilter filter = const StockDocFilter(),
    String? sort,
    String? order,
  }) async {
    lastFilter = filter;
    return PagedResult(
      items: [
        for (final id in ['a', 'b'])
          StockDocListItem(
            id: id,
            billNo: 'OUT-$id',
            docType: type.code,
            status: 0,
          ),
      ],
      page: page,
      size: 20,
      total: 2,
      totalPages: 1,
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repo repo,
  Widget page, {
  bool approve = true,
  Size size = const Size(1300, 850),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue({
          Perm.stockDocView,
          if (approve) Perm.stockDocApprove,
        }),
        sharedPreferencesProvider.overrideWithValue(prefs),
        masterNameServiceProvider.overrideWithValue(_Names()),
        documentScopeCapabilityRepositoryProvider.overrideWithValue(
          const _Scope(),
        ),
        stockDocRepositoryProvider(repo.type).overrideWithValue(repo),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
  );
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(UtenButton, '确认批量出库'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final type in [StockDocType.otherOut, StockDocType.finishedOut]) {
    testWidgets(
      '${type.code} reviews live lines, requires second confirmation and completes selected documents',
      (tester) async {
        final repo = _Repo(type);
        await _pump(
          tester,
          repo,
          WarehouseStockBatchOutboundPage(
            docType: type,
            documentIds: const ['a', 'b'],
          ),
        );
        final table = tester
            .widget<MasterDataTableView<WarehouseStockOutboundRow>>(
              find.byKey(const Key('warehouse-stock-outbound-detail-table')),
            );
        expect(table.selectedIds, {'a', 'b'});
        final header = find.byKey(
          const Key('warehouse-stock-batch-outbound-header'),
        );
        expect(
          find.descendant(of: header, matching: find.byType(UtenCard)),
          findsNWidgets(2),
        );
        expect(
          find.descendant(
            of: header,
            matching: find.textContaining('仓管员(E01)', findRichText: true),
          ),
          findsNWidgets(2),
        );
        expect(
          find.descendant(
            of: header,
            matching: find.textContaining(
              '2026-09-12 09:30',
              findRichText: true,
            ),
          ),
          findsNWidgets(2),
        );
        expect(
          find.descendant(of: header, matching: find.text('轨道车间')),
          findsNothing,
        );
        expect(
          find.descendant(of: header, matching: find.textContaining('随单备注')),
          findsNothing,
        );
        expect(
          table.columns
              .firstWhere((c) => c.key == 'warehouse')
              .value(table.items.first),
          '轨道车间',
        );
        expect(
          table.columns
              .firstWhere((c) => c.key == 'remark')
              .value(table.items.first),
          '明细备注-a',
        );
        expect(
          table.columns
              .firstWhere((c) => c.key == 'documentRemark')
              .value(table.items.first),
          '随单备注-a',
        );
        expect(
          tester
              .widget<UtenButton>(
                find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
              )
              .type,
          UtenButtonType.danger,
        );
        expect(
          table.columns
              .firstWhere((c) => c.key == 'qty')
              .value(table.items.first),
          '0.0001',
        );
        expect(
          table.columns
              .firstWhere((c) => c.key == 'place')
              .value(table.items.first),
          '33333',
        );
        expect(repo.approved, isEmpty);
        await _confirm(tester);
        expect(repo.approved, ['a', 'b']);
        expect(find.text('已出库'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${type.code} list supports multi-selection and clears it on search change',
      (tester) async {
        final repo = _Repo(type);
        final keyword = ValueNotifier('first');
        addTearDown(keyword.dispose);
        await _pump(
          tester,
          repo,
          Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: keyword,
              builder: (_, value, _) =>
                  WarehouseStockDocSegment(docType: type, keyword: value),
            ),
          ),
        );
        await tester.tap(find.text('草稿'));
        await tester.pumpAndSettle();
        final key = Key('stock-doc-segment-table-${type.code}');
        final table = tester.widget<MasterDataTableView<StockDocListItem>>(
          find.byKey(key),
        );
        expect(table.selectable, isTrue);
        expect(repo.lastFilter?.keyword, 'first');
        table.onSelectedIdsChanged!({'a', 'b'});
        await tester.pumpAndSettle();
        expect(find.text('批量出库'), findsOneWidget);
        keyword.value = 'second';
        await tester.pumpAndSettle();
        expect(repo.lastFilter?.keyword, 'second');
        expect(
          tester
              .widget<MasterDataTableView<StockDocListItem>>(find.byKey(key))
              .selectedIds,
          isEmpty,
        );
        await tester.tap(find.text('已审'));
        await tester.pumpAndSettle();
        final updated = tester.widget<MasterDataTableView<StockDocListItem>>(
          find.byKey(key),
        );
        expect(updated.selectedIds, isEmpty);
        expect(updated.selectable, isFalse);
      },
    );
  }

  testWidgets(
    'uncertain response stops later writes; refresh never repeats a successful document',
    (tester) async {
      final repo = _Repo(StockDocType.otherOut)..failId = 'b';
      await _pump(
        tester,
        repo,
        const WarehouseStockBatchOutboundPage(
          docType: StockDocType.otherOut,
          documentIds: ['a', 'b', 'c'],
        ),
      );
      await _confirm(tester);
      expect(repo.approved, ['a', 'b']);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
            )
            .onPressed,
        isNull,
      );
      repo.statuses['b'] = 1; // The timed-out request did commit.
      repo.failId = null;
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      await _confirm(tester);
      expect(repo.approved, ['a', 'b', 'c']);
    },
  );

  testWidgets('a draft changed after review is not approved', (tester) async {
    final repo = _Repo(StockDocType.otherOut);
    await _pump(
      tester,
      repo,
      const WarehouseStockBatchOutboundPage(
        docType: StockDocType.otherOut,
        documentIds: ['a'],
      ),
    );
    repo.quantities['a'] = 500;
    await _confirm(tester);
    expect(repo.approved, isEmpty);
  });

  testWidgets('foreign owner is not selectable and narrow review fits', (
    tester,
  ) async {
    final repo = _Repo(StockDocType.otherOut);
    await _pump(
      tester,
      repo,
      const WarehouseStockBatchOutboundPage(
        docType: StockDocType.otherOut,
        documentIds: ['a', 'foreign'],
      ),
      size: const Size(390, 844),
    );
    final table = tester.widget<MasterDataTableView<WarehouseStockOutboundRow>>(
      find.byKey(const Key('warehouse-stock-outbound-detail-table')),
    );
    expect(table.selectedIds, {'a'});
    expect(table.idOf!(table.items.last), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only users have no batch action', (tester) async {
    final repo = _Repo(StockDocType.otherOut);
    await _pump(
      tester,
      repo,
      const WarehouseStockBatchOutboundPage(
        docType: StockDocType.otherOut,
        documentIds: ['a'],
      ),
      approve: false,
    );
    expect(
      find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
      findsNothing,
    );
    expect(repo.approved, isEmpty);
  });

  testWidgets('single outbound uses the same table and reviewed approval', (
    tester,
  ) async {
    final repo = _Repo(StockDocType.otherOut);
    await _pump(
      tester,
      repo,
      const StockDocDetailPage(docType: StockDocType.otherOut, id: 'a'),
    );
    expect(
      find.byKey(const Key('warehouse-stock-outbound-detail-table')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(UtenButton, '确认出库'));
    await tester.pumpAndSettle();
    expect(repo.approved, isEmpty);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(UtenButton, '确认出库'),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.approved, ['a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single outbound failure requires a fresh review token', (
    tester,
  ) async {
    final repo = _Repo(StockDocType.otherOut)..failId = 'a';
    await _pump(
      tester,
      repo,
      const StockDocDetailPage(docType: StockDocType.otherOut, id: 'a'),
    );
    await tester.tap(find.widgetWithText(UtenButton, '确认出库'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(UtenButton, '确认出库'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确认出库'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确认出库'))
          .onPressed,
      isNotNull,
    );
    expect(repo.approved, ['a']);
  });
}
