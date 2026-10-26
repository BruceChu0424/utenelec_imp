import '../../support/native_facet_fake_transport.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_document_history_config.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_document_history.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_document_history_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_document_history_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_document_history_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

const _initialSession = SessionState(
  status: AuthStatus.authenticated,
  user: AppUser(id: 'warehouse-keeper', code: 'WH01', name: '仓管甲'),
);
final _session = StateProvider<SessionState>((_) => _initialSession);
final _warehouse = StateProvider<WarehouseTaskScope>(
  (_) => const WarehouseTaskScope.warehouse('A'),
);
final _server = StateProvider<String>((_) => 'https://a.invalid/api');
final _permissions = StateProvider<Set<String>>(
  (_) => {
    Perm.warehousePurchaseReceiptHistoryView,
    Perm.warehouseSubcontractReceiptHistoryView,
    Perm.warehouseSubcontractOutboundHistoryView,
    Perm.warehouseSubcontractFinishedReturnHistoryView,
    Perm.warehouseSubcontractMaterialReturnHistoryView,
    Perm.warehouseSubcontractWasteHistoryView,
  },
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => ref.watch(_session);
}

Future<ProviderContainer> _boot(
  _HistoryApi api, {
  _HistoryApi? otherServer,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      apiClientProvider.overrideWith((ref) {
        final server = ref.watch(apiBaseUrlProvider);
        return server == 'https://a.invalid/api' ? api : otherServer ?? api;
      }),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      warehouseTaskScopeProvider.overrideWith((ref) => ref.watch(_warehouse)),
    ],
  );
  // Use a real authenticated session and a valid /auth/me snapshot. An empty
  // API body would schedule the production 5/15/45-second snapshot retry timer.
  final snapshot = await container.read(sessionSnapshotProvider.future);
  expect(snapshot, isNotNull);
  expect(
    container.read(authenticatedScopeProvider)?.userId,
    'warehouse-keeper',
  );
  return container;
}

void main() {
  setUp(RecentMeSnapshot.clear);

  for (final type in WarehouseDocumentHistoryType.values) {
    test(
      '${type.segment}: list, facets and detail bind the same warehouse',
      () async {
        final api = _HistoryApi();
        final repository = WarehouseDocumentHistoryRepository(
          api,
          type,
          warehouseScope: const WarehouseTaskScope.warehouse('A'),
        );
        final result = await repository.list(
          page: 3,
          keyword: '  G-001  ',
          status: ' 1 ',
          dateFrom: '2026-10-01',
          dateTo: '2026-10-12',
          sort: 'billNo',
          order: 'desc',
          billNo: ' A-NO ',
          sourceDocNo: ' SOURCE-A ',
        );
        final list = api.calls.last;
        expect(list.path, '/warehouse/document-history/${type.segment}');
        expect(list.query, {
          'page': 3,
          'size': 20,
          'scopeWarehouseId': 'A',
          'keyword': 'G-001',
          'status': '1',
          'dateFrom': '2026-10-01',
          'dateTo': '2026-10-12',
          'sort': 'billNo',
          'order': 'desc',
          'billNo': 'A-NO',
          'sourceDocNo': 'SOURCE-A',
        });
        expect(result.items.single.type, type);
        await repository.billNoFacets(
          keyword: ' G-001 ',
          status: ' 1 ',
          dateFrom: '2026-10-01',
          dateTo: '2026-10-12',
        );
        expect(api.calls.last.path, '${list.path}/facets');
        expect(api.calls.last.query, {
          'scopeWarehouseId': 'A',
          'keyword': 'G-001',
          'status': '1',
          'dateFrom': '2026-10-01',
          'dateTo': '2026-10-12',
        });
        final detail = await repository.detail(' id/with space ');
        expect(api.calls.last.path, '${list.path}/id%2Fwith%20space');
        expect(api.calls.last.query, {'scopeWarehouseId': 'A'});
        expect(detail.header.type, type);

        final defaultScope = WarehouseDocumentHistoryRepository(api, type);
        await defaultScope.list();
        expect(api.calls.last.query, isNot(contains('scopeWarehouseId')));
        await defaultScope.billNoFacets();
        expect(api.calls.last.query, isEmpty);
        await defaultScope.detail('default-id');
        expect(api.calls.last.query, isEmpty);
      },
    );
  }

  test(
    'production family provider rebuilds for actor, server, warehouse and permissions',
    () async {
      final api = _HistoryApi();
      final apiB = _HistoryApi();
      final container = await _boot(api, otherServer: apiB);
      addTearDown(container.dispose);
      final provider = warehouseDocumentHistoryRepositoryProvider(
        WarehouseDocumentHistoryType.subcontractWaste,
      );
      container.listen(provider, (_, _) {});
      WarehouseDocumentHistoryRepository current() =>
          container.read(provider) as WarehouseDocumentHistoryRepository;
      var previous = current();
      expect(previous.api, same(api));
      expect(previous.warehouseScope.warehouseId, 'A');

      container.read(_session.notifier).state = const SessionState(
        status: AuthStatus.authenticated,
        user: AppUser(id: 'warehouse-keeper', code: 'WH01', name: '仓管甲'),
        actor: AppUser(id: 'operator', code: 'OP01', name: '操作人'),
      );
      await container.pump();
      expect(current(), isNot(same(previous)));
      expect(container.read(authenticatedScopeProvider)?.actorId, 'operator');
      previous = current();

      container.read(_server.notifier).state = 'https://b.invalid/api';
      await container.pump();
      expect(current(), isNot(same(previous)));
      expect(current().api, same(apiB));
      expect(await container.read(sessionSnapshotProvider.future), isNotNull);
      previous = current();

      container.read(_warehouse.notifier).state =
          const WarehouseTaskScope.warehouse('B');
      await container.pump();
      expect(current(), isNot(same(previous)));
      expect(current().warehouseScope.warehouseId, 'B');
      previous = current();

      container.read(_permissions.notifier).state = {
        Perm.warehouseSubcontractWasteHistoryView,
      };
      await container.pump();
      expect(current(), isNot(same(previous)));
      await current().list();
      expect(apiB.calls.last.query['scopeWarehouseId'], 'B');
      expect(container.read(sessionSnapshotProvider).hasError, isFalse);
    },
  );

  for (final change in ['warehouse', 'type']) {
    testWidgets(
      'history view clears rows and buckets on $change change; late reads stay discarded',
      (tester) async {
        _viewport(tester);
        final api = _HistoryApi();
        final container = await _boot(api);
        addTearDown(container.dispose);
        final type = ValueNotifier(
          WarehouseDocumentHistoryType.subcontractReturn,
        );
        addTearDown(type.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder(
                  valueListenable: type,
                  builder: (_, value, _) => WarehouseDocumentHistoryView(
                    key: const Key('reused-history-view'),
                    type: value,
                    embedded: true,
                    keyword: 'same-keyword',
                    dateFrom: '2026-10-01',
                    dateTo: '2026-10-12',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        MasterDataTableView<WarehouseDocumentHistorySummary> table() =>
            tester.widget(
              find.byKey(Key('warehouse-history-table-${type.value.segment}')),
            );
        final firstCandidates = await tester.runAsync(
          () => table().facetPageLoaders['billNo']!('', 1),
        );
        expect(firstCandidates!.items.single.value, 'A-BUCKET');
        table().onFilterChanged('status', '1');
        await tester.pumpAndSettle();
        table().onFilterChanged('billNo', 'OLD-NO');
        await tester.pumpAndSettle();
        table().onFilterChanged('sourceDocNo', 'OLD-SOURCE');
        await tester.pumpAndSettle();
        table().onSortChange!('billNo', false);
        await tester.pumpAndSettle();
        table().onPageChange!(3);
        await tester.pumpAndSettle();
        expect(table().currentPage, 3);

        final oldFacets = Completer<Map<String, dynamic>>();
        api.facetsGate = oldFacets;
        final oldCandidateRead = table().facetPageLoaders['billNo']!('', 1);
        await tester.pump();
        expect(api.facetsGate, isNull);
        final oldRows = Completer<Map<String, dynamic>>();
        api.listGate = oldRows;
        table().onRetry!();
        await tester.pump();
        expect(api.listGate, isNull);
        final newRows = Completer<Map<String, dynamic>>();
        api.listGate = newRows;
        final oldType = type.value;
        if (change == 'warehouse') {
          container.read(_warehouse.notifier).state =
              const WarehouseTaskScope.warehouse('B');
        } else {
          type.value = WarehouseDocumentHistoryType.subcontractWaste;
        }
        await tester.pump();
        await tester.pump();
        expect(table().items, isEmpty);
        expect(table().facets['billNo'], isEmpty);
        expect(table().filters.values.whereType<String>(), isEmpty);
        expect(table().sortColumn, isNull);
        final newRequest = api.calls.lastWhere(
          (call) => call.query.containsKey('page'),
        );
        expect(
          newRequest.path,
          '/warehouse/document-history/${type.value.segment}',
        );
        expect(
          newRequest.query['scopeWarehouseId'],
          change == 'warehouse' ? 'B' : 'A',
        );
        expect(newRequest.query['page'], 1);
        expect(newRequest.query['status'], isNull);
        expect(newRequest.query['billNo'], isNull);
        expect(newRequest.query['sourceDocNo'], isNull);
        expect(newRequest.query['keyword'], 'same-keyword');
        expect(newRequest.query['dateFrom'], '2026-10-01');
        expect(newRequest.query['dateTo'], '2026-10-12');

        oldRows.complete(_listJson(oldType, 'LATE-OLD', 3));
        oldFacets.complete(_facetJson('LATE-OLD'));
        await oldCandidateRead;
        await tester.pump();
        expect(table().items, isEmpty);
        expect(table().facets['billNo'], isEmpty);
        final scope = change == 'warehouse' ? 'B' : 'A';
        newRows.complete(_listJson(type.value, scope, 1));
        await tester.pumpAndSettle();
        expect(table().items.single.billNo, '$scope-${type.value.segment}-1');
        expect(table().items.single.type, type.value);
        final currentCandidates = await tester.runAsync(
          () => table().facetPageLoaders['billNo']!('', 1),
        );
        expect(currentCandidates!.items.single.value, '$scope-BUCKET');
        expect(find.text('LATE-OLD'), findsNothing);
        expect(table().currentPage, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final change in ['warehouse', 'id', 'type']) {
    testWidgets(
      'history detail clears physical facts on $change change and rejects late object response',
      (tester) async {
        _viewport(tester);
        final api = _HistoryApi();
        final container = await _boot(api);
        addTearDown(container.dispose);
        final object = ValueNotifier((
          WarehouseDocumentHistoryType.purchaseReceipt,
          'old-id',
        ));
        addTearDown(object.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: ValueListenableBuilder(
                valueListenable: object,
                builder: (_, value, _) => WarehouseDocumentHistoryDetailPage(
                  key: const Key('reused-history-detail'),
                  type: value.$1,
                  id: value.$2,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('A-old-id-货物'), findsWidgets);
        final oldDetail = Completer<Map<String, dynamic>>();
        api.detailGate = oldDetail;
        await tester.tap(
          find.byKey(
            Key('warehouse-history-detail-refresh-${object.value.$1.segment}'),
          ),
        );
        await tester.pump();
        expect(api.detailGate, isNull);
        final newDetail = Completer<Map<String, dynamic>>();
        api.detailGate = newDetail;
        if (change == 'warehouse') {
          container.read(_warehouse.notifier).state =
              const WarehouseTaskScope.warehouse('B');
        } else if (change == 'id') {
          object.value = (object.value.$1, 'new-id');
        } else {
          object.value = (
            WarehouseDocumentHistoryType.subcontractMaterialReturn,
            object.value.$2,
          );
        }
        await tester.pump();
        await tester.pump();
        expect(find.text('A-old-id-货物'), findsNothing);
        expect(
          find.byKey(
            Key('warehouse-history-detail-table-${object.value.$1.segment}'),
          ),
          findsNothing,
        );
        final scope = change == 'warehouse' ? 'B' : 'A';
        final request = api.calls.lastWhere(
          (call) => call.path.startsWith('/warehouse/document-history/'),
        );
        expect(
          request.path,
          '/warehouse/document-history/${object.value.$1.segment}/${object.value.$2}',
        );
        expect(request.query, {'scopeWarehouseId': scope});
        oldDetail.complete(_detailJson('LATE-OLD', 'old-id'));
        await tester.pump();
        expect(find.text('LATE-OLD-old-id-货物'), findsNothing);
        newDetail.complete(_detailJson(scope, object.value.$2));
        await tester.pumpAndSettle();
        expect(find.text('$scope-${object.value.$2}-货物'), findsWidgets);
        final table = tester
            .widget<MasterDataTableView<WarehouseDocumentPhysicalItem>>(
              find.byKey(
                Key(
                  'warehouse-history-detail-table-${object.value.$1.segment}',
                ),
              ),
            );
        expect(table.items.single.goodsName, '$scope-${object.value.$2}-货物');
        expect(find.text('LATE-OLD-old-id-货物'), findsNothing);
        expect(container.read(sessionSnapshotProvider).hasError, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<String, dynamic> _listJson(
  WarehouseDocumentHistoryType type,
  String scope,
  int page,
) => {
  'items': [
    {
      'id': '$scope-${type.segment}-$page',
      'billNo': '$scope-${type.segment}-$page',
      'status': 1,
      'closed': false,
      'lineCount': 1,
      'warehouseName': scope,
    },
  ],
  'page': page,
  'size': 1,
  'total': 3,
  'totalPages': 3,
};

Map<String, dynamic> _facetJson(String scope) => {
  'billNo': [
    {'value': '$scope-BUCKET', 'label': '$scope-BUCKET', 'count': 3},
  ],
  'sourceDocNo': [
    {'value': '$scope-SOURCE', 'label': '$scope-SOURCE', 'count': 3},
  ],
};

Map<String, dynamic> _detailJson(String scope, String id) => {
  'id': id,
  'billNo': '$scope-$id',
  'status': 1,
  'closed': false,
  'warehouseName': scope,
  'lineCount': 1,
  'lines': [
    {
      'id': '$id-line',
      'lineNumber': 1,
      'goodsCode': '$scope-$id-CODE',
      'goodsName': '$scope-$id-货物',
      'quantity': '10.1250',
      'unitName': '件',
    },
  ],
};

class _Call {
  _Call(this.path, Map<String, dynamic>? query)
    : query = Map<String, dynamic>.from(query ?? const {});
  final String path;
  final Map<String, dynamic> query;
}

class _HistoryApi extends ApiClient with NativeFacetFakeTransport {
  _HistoryApi() : super(Dio());
  final calls = <_Call>[];
  Completer<Map<String, dynamic>>? listGate;
  Completer<Map<String, dynamic>>? facetsGate;
  Completer<Map<String, dynamic>>? detailGate;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add(_Call(path, query));
    if (path == ApiEndpoints.authMe) {
      return {
        'id': 'warehouse-keeper',
        'code': 'WH01',
        'name': '仓管甲',
        'session': <String, dynamic>{
          'delegableSurfaceKeys': <String>[],
          'documentScopes': <String, dynamic>{},
          'preferences': <String, dynamic>{},
        },
      };
    }
    if (!path.startsWith('/warehouse/document-history/')) return {};
    final parts = path.split('/');
    final type = WarehouseDocumentHistoryType.tryParse(parts[3])!;
    final scope = query?['scopeWarehouseId']?.toString() ?? 'DEFAULT';
    if (parts.length == 4) {
      final gate = listGate;
      listGate = null;
      return gate == null
          ? _listJson(type, scope, query?['page'] as int? ?? 1)
          : gate.future;
    }
    if (parts.last == 'facets') {
      final gate = facetsGate;
      facetsGate = null;
      return gate == null ? _facetJson(scope) : gate.future;
    }
    final gate = detailGate;
    detailGate = null;
    return gate == null
        ? _detailJson(scope, Uri.decodeComponent(parts.last))
        : gate.future;
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
}
