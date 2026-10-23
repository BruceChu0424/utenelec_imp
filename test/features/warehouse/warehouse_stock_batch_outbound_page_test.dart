import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
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
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import '../../helpers/document_scope_fixture.dart';

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

class _Repo extends StockDocRepository {
  _Repo(StockDocType type) : super(ApiClient(Dio()), type);
  final statuses = <String, int>{'done': 1};
  final quantities = <String, double>{};
  final approved = <String>[];
  String? failId;
  bool withSecondItem = false;
  final extraItemSources = <String>{};
  Completer<StockDocOutboundReview>? pendingReview;
  Completer<StockDocDetail>? pendingApprove;
  final reviewCalls = <String>[];
  final unreadable = <String>{};
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
      if (withSecondItem || extraItemSources.contains(id))
        StockDocItem(
          id: 'unselected-$id',
          goodsId: 'goods-other',
          qty: 5,
          qtyText: '5',
          unitId: 'unit',
        ),
      StockDocItem(
        id: 'line-$id',
        goodsId: 'goods',
        qty: quantities[id] ?? 0.0001,
        qtyText: (quantities[id] ?? 0.0001).toString(),
        unitId: 'unit',
        place: '33333',
        remark: '明细备注-$id',
      ),
    ],
  );

  @override
  Future<StockDocOutboundReview> review(String id) async {
    reviewCalls.add(id);
    if (unreadable.contains(id)) {
      throw ApiException('NOT_FOUND', '来源不可读取', httpStatus: 404);
    }
    if (pendingReview case final pending?) return pending.future;
    return StockDocOutboundReview(
      document: await detail(id),
      reviewToken: '${statuses[id] ?? 0}:${quantities[id] ?? 0.0001}',
    );
  }

  @override
  Future<StockDocOutboundReview> reviewNative(String id) => review(id);

  @override
  Future<StockDocDetail> approveReviewed(
    String id, {
    required String expectedReviewToken,
    List<String>? itemIds,
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
    if (pendingApprove case final pending?) return pending.future;
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
    final items = [
      for (final id in ['a', 'b', 'done'])
        if (((statuses[id] ?? 0) == 0) ==
                (filter.view == WarehouseTaskView.active) &&
            (filter.status == null || filter.status == (statuses[id] ?? 0)))
          StockDocListItem(
            id: id,
            billNo: 'OUT-$id',
            docType: type.code,
            status: statuses[id] ?? 0,
          ),
    ];
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

final _actor = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'me'),
);
final _permissions = StateProvider<Set<String>>(
  (_) => const {Perm.stockDocView, Perm.stockDocApprove},
);
final _client = StateProvider<ApiClient>(
  (_) => ApiClient(Dio(BaseOptions(baseUrl: 'https://stock-test.invalid/api'))),
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repo repo,
  Widget page, {
  bool approve = true,
  bool settle = true,
  AuthenticatedScope? identity = const AuthenticatedScope(userId: 'me'),
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
        _actor.overrideWith((_) => identity),
        _permissions.overrideWith(
          (_) => {Perm.stockDocView, if (approve) Perm.stockDocApprove},
        ),
        _client.overrideWith(
          (_) => ApiClient(
            Dio(BaseOptions(baseUrl: 'https://stock-test.invalid/api')),
          ),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_actor)),
        apiClientProvider.overrideWith((ref) => ref.watch(_client)),
        sessionProvider.overrideWith(_Session.new),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(prefs),
        masterNameServiceProvider.overrideWithValue(_Names()),
        documentScopeOverride(owners: const {'me'}),
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
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  expect(tester.takeException(), isNull);
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
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
  for (final change in ['cancelled', 'items-changed']) {
    testWidgets('unknown stock A can be read when unsent B is $change', (
      tester,
    ) async {
      final repo = _Repo(StockDocType.otherOut)..failId = 'a';
      await _pump(
        tester,
        repo,
        const WarehouseStockBatchOutboundPage(
          docType: StockDocType.otherOut,
          documentIds: ['a', 'b'],
          selectedItemIds: ['line-a', 'line-b'],
        ),
      );
      await _confirm(tester);
      repo.statuses['a'] = 1;
      if (change == 'cancelled') {
        repo.statuses['b'] = 3;
      } else {
        repo.extraItemSources.add('b');
      }
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      final table = tester.widget<WarehouseStockOutboundDetailTable>(
        find.byType(WarehouseStockOutboundDetailTable),
      );
      expect(
        table.documents.singleWhere((document) => document.id == 'a').status,
        1,
      );
      expect(repo.approved, ['a']);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
            )
            .onPressed,
        isNull,
      );
      if (change == 'items-changed') {
        expect(find.textContaining('来源 b'), findsWidgets);
        expect(
          table.documents.singleWhere((document) => document.id == 'b').items,
          isEmpty,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
  for (final hidden in ['b', 'a']) {
    testWidgets(
      'unknown stock approval refresh isolates unavailable source $hidden without another POST',
      (tester) async {
        final repo = _Repo(StockDocType.otherOut)..failId = 'a';
        await _pump(
          tester,
          repo,
          const WarehouseStockBatchOutboundPage(
            docType: StockDocType.otherOut,
            documentIds: ['a', 'b'],
            selectedItemIds: ['line-a', 'line-b'],
          ),
        );
        await _confirm(tester);
        expect(repo.approved, ['a']);
        repo.statuses['a'] = 1;
        repo.unreadable.add(hidden);
        await tester.tap(find.text('刷新'));
        await tester.pumpAndSettle();
        expect(repo.approved, ['a']);
        expect(find.textContaining('随单备注-$hidden'), findsNothing);
        expect(find.textContaining('来源 $hidden'), findsWidgets);
        if (hidden == 'a') {
          expect(
            tester
                .widget<UtenButton>(
                  find.byKey(
                    const Key('warehouse-stock-batch-outbound-confirm'),
                  ),
                )
                .onPressed,
            isNull,
          );
          repo.unreadable.remove('a');
          await tester.tap(find.text('刷新'));
          await tester.pumpAndSettle();
          expect(repo.approved, ['a']);
        } else {
          expect(find.textContaining('来源 b'), findsWidgets);
          final table = tester.widget<WarehouseStockOutboundDetailTable>(
            find.byType(WarehouseStockOutboundDetailTable),
          );
          expect(
            table.documents
                .singleWhere((document) => document.id == 'a')
                .status,
            1,
          );
          expect(
            table.documents.singleWhere((document) => document.id == 'b').items,
            isEmpty,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('没有登录身份的核对页不得读取旧单据或显示审批入口', (tester) async {
    final repo = _Repo(StockDocType.otherOut);
    await _pump(
      tester,
      repo,
      const WarehouseStockBatchOutboundPage(
        docType: StockDocType.otherOut,
        documentIds: ['a'],
      ),
      identity: null,
    );
    expect(repo.reviewCalls, isEmpty);
    expect(repo.approved, isEmpty);
    expect(
      find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
      findsNothing,
    );
  });
  for (final change in ['actor', 'permissions', 'readonly', 'endpoint']) {
    testWidgets('native review $change在确认框期间变化后不能沿用旧核对写入', (tester) async {
      final repo = _Repo(StockDocType.otherOut);
      final container = await _pump(
        tester,
        repo,
        const WarehouseStockBatchOutboundPage(
          docType: StockDocType.otherOut,
          documentIds: ['a'],
        ),
      );
      await tester.tap(
        find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
      );
      await tester.pumpAndSettle();
      switch (change) {
        case 'actor':
          container.read(_actor.notifier).state = const AuthenticatedScope(
            userId: 'other',
          );
        case 'permissions':
          container.read(_permissions.notifier).state = const {
            Perm.stockDocView,
          };
        case 'readonly':
          container.read(_actor.notifier).state = const AuthenticatedScope(
            userId: 'me',
            readOnly: true,
          );
        case 'endpoint':
          container.read(_client.notifier).state = ApiClient(
            Dio(BaseOptions(baseUrl: 'https://other-test.invalid/api')),
          );
      }
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(UtenButton, '确认批量出库'),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.approved, isEmpty);
      expect(find.text('OUT-a'), findsNothing);
      expect(find.text('账号、服务器或权限已变化，请重新进入核对'), findsOneWidget);
      container.read(_actor.notifier).state = const AuthenticatedScope(
        userId: 'me',
      );
      container.read(_permissions.notifier).state = const {
        Perm.stockDocView,
        Perm.stockDocApprove,
      };
      await tester.pumpAndSettle();
      final before = repo.reviewCalls.length;
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(repo.reviewCalls.length, before);
      expect(repo.approved, isEmpty);
    });
  }
  testWidgets('旧身份迟到GET不能回填且返回原身份也不能刷新复活旧页面', (tester) async {
    final pending = Completer<StockDocOutboundReview>();
    final repo = _Repo(StockDocType.otherOut)..pendingReview = pending;
    final container = await _pump(
      tester,
      repo,
      const WarehouseStockBatchOutboundPage(
        docType: StockDocType.otherOut,
        documentIds: ['a'],
      ),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(repo.reviewCalls, ['a']);
    container.read(_actor.notifier).state = const AuthenticatedScope(
      userId: 'other',
    );
    await tester.pump();
    pending.complete(
      StockDocOutboundReview(
        document: await repo.detail('a'),
        reviewToken: 'old',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('OUT-a'), findsNothing);
    container.read(_actor.notifier).state = const AuthenticatedScope(
      userId: 'me',
    );
    await tester.pumpAndSettle();
    expect(find.text('OUT-a'), findsNothing);
    expect(repo.approved, isEmpty);
  });
  testWidgets('逐单POST期间换人保留已派发命令但不继续下一单或渲染旧成功', (tester) async {
    final pending = Completer<StockDocDetail>();
    final repo = _Repo(StockDocType.otherOut)..pendingApprove = pending;
    final container = await _pump(
      tester,
      repo,
      const WarehouseStockBatchOutboundPage(
        docType: StockDocType.otherOut,
        documentIds: ['a', 'b'],
      ),
    );
    await tester.tap(
      find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(UtenButton, '确认批量出库'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(repo.approved, ['a']);
    container.read(_actor.notifier).state = const AuthenticatedScope(
      userId: 'other',
    );
    await tester.pump();
    repo.statuses['a'] = 1;
    pending.complete(await repo.detail('a'));
    await tester.pumpAndSettle();
    expect(repo.approved, ['a']);
    expect(find.text('OUT-a'), findsNothing);
  });
  for (final type in [StockDocType.otherIn]) {
    testWidgets(
      '${type.code} native inbound reviews selected complete documents',
      (tester) async {
        final repo = _Repo(type);
        await _pump(
          tester,
          repo,
          WarehouseStockBatchOutboundPage(
            docType: type,
            documentIds: const ['one'],
            selectedItemIds: const ['line-one'],
          ),
        );
        expect(find.text('批量入库核对'), findsOneWidget);
        expect(find.text('入库数量'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(UtenButton, '确认批量入库'),
          ),
        );
        await tester.pumpAndSettle();
        expect(repo.approved, ['one']);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'partial stock-out selection previews one line and never approves siblings',
    (tester) async {
      final repo = _Repo(StockDocType.otherOut)..withSecondItem = true;
      await _pump(
        tester,
        repo,
        const WarehouseStockBatchOutboundPage(
          docType: StockDocType.otherOut,
          documentIds: ['one'],
          selectedItemIds: ['line-one'],
        ),
      );
      final table = tester.widget<WarehouseStockOutboundDetailTable>(
        find.byType(WarehouseStockOutboundDetailTable),
      );
      expect(table.documents.single.items.map((item) => item.id), ['line-one']);
      expect(find.textContaining('该单据需整单确认'), findsWidgets);
      await tester.tap(
        find.byKey(const Key('warehouse-stock-batch-outbound-confirm')),
      );
      await tester.pumpAndSettle();
      expect(repo.approved, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

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
        // 2026-10-10「数量 + 单位」内联口径：数量列直接带行单位（件）。
        expect(
          table.columns
              .firstWhere((c) => c.key == 'qty')
              .value(table.items.first),
          '0.0001 件',
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
        // 草稿段经 FormDraftCategoryTable 渲染合并表，按 key 直接取 dynamic。
        final table = tester.widget<MasterDataTableView<dynamic>>(
          find.byKey(key),
        );
        expect(table.selectable, isTrue);
        expect(repo.lastFilter?.keyword, 'first');
        expect(repo.lastFilter?.view, WarehouseTaskView.active);
        expect(repo.lastFilter?.status, 0);
        table.onSelectedIdsChanged!({'a', 'b'});
        await tester.pumpAndSettle();
        expect(find.text('批量出库'), findsOneWidget);
        keyword.value = 'second';
        await tester.pumpAndSettle();
        expect(repo.lastFilter?.keyword, 'second');
        expect(
          tester
              .widget<MasterDataTableView<dynamic>>(find.byKey(key))
              .selectedIds,
          isEmpty,
        );
        await tester.tap(find.text('历史单据'));
        await tester.pumpAndSettle();
        final updated = tester.widget<MasterDataTableView<StockDocListItem>>(
          find.byKey(key),
        );
        expect(updated.selectedIds, isEmpty);
        expect(updated.selectable, isFalse);
        expect(updated.items.map((row) => row.id), ['done']);
        expect(repo.lastFilter?.view, WarehouseTaskView.history);
        expect(repo.lastFilter?.status, isNull);
        expect(repo.lastFilter?.keyword, 'second');
        expect(find.text('批量出库'), findsNothing);
        await tester.tap(find.text('草稿'));
        await tester.pumpAndSettle();
        final restored = tester.widget<MasterDataTableView<dynamic>>(
          find.byKey(key),
        );
        expect(restored.selectable, isTrue);
        expect(restored.selectedIds, isEmpty);
        expect(repo.lastFilter?.view, WarehouseTaskView.active);
        expect(repo.lastFilter?.status, 0);
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
