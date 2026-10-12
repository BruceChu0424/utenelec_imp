import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_batch_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_material_return_batch_receive_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import '../../helpers/badge_summary_fixture.dart';

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Storage implements FormDraftStorage {
  final records = <String, String>{};
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final posts = <({String path, Map<String, dynamic> body})>[];
  bool interrupt = true;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/master/warehouses/dict'
      ? [
          {'id': 'main', 'name': '主仓', 'accountable': false},
          {
            'id': 'normal',
            'name': '收料仓',
            'parentId': 'main',
            'selectableForNew': true,
          },
        ]
      : [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'id': path.split('/').last,
    'docType': 'WDRAW',
    'status': 0,
    'billNo': path.split('/').last,
    'productionMaterialReturn': true,
    'materialReturnMainWarehouseId': 'main',
    'items': <Map<String, dynamic>>[],
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path: path, body: Map<String, dynamic>.from(body as Map)));
    if (interrupt && (path.contains('batch') || path.contains('return-b'))) {
      interrupt = false;
      throw NetworkTimeoutException();
    }
    return {
      'id': path.split('/')[3],
      'status': 1,
      'confirmedCount': 1,
      'replay': posts.length > 1,
      'items': <Object>[],
    };
  }
}

ProviderContainer _container(_Api api) => ProviderContainer(
  overrides: [
    apiClientProvider.overrideWithValue(api),
    apiBaseUrlProvider.overrideWithValue('https://draft-test.example/api'),
    authenticatedScopeProvider.overrideWithValue(
      const AuthenticatedScope(userId: 'keeper'),
    ),
    currentPermissionsProvider.overrideWithValue({
      Perm.stockDocView,
      Perm.stockDocApprove,
    }),
    isSuperAdminProvider.overrideWithValue(false),
    formDraftStorageProvider.overrideWithValue(_Storage()),
    sessionSnapshotProvider.overrideWith(_Snapshot.new),
    fixedBadgeSummaryOverride(),
    masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
    stockDocRepositoryProvider(
      StockDocType.wdraw,
    ).overrideWithValue(StockDocRepository(api, StockDocType.wdraw)),
  ],
);

ProductionFinishedInboundTask _task(String id) => ProductionFinishedInboundTask(
  taskStage: ProductionFinishedInboundTaskStage.finalCount,
  taskId: id,
  documentId: id,
  documentNo: id,
  documentDate: DateTime(2026, 10, 11),
  lineCount: 1,
  pendingQty: 10,
  createdAt: DateTime(2026, 10, 11),
  residualTask: false,
);

void main() {
  testWidgets(
    'finished batch timeout restores original selection and random idempotency key',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api();
      final container = _container(api);
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: RouteName.warehouseProductionFinishedBatchStockIn,
        routes: [
        GoRoute(path: RouteName.warehouseProductionFinishedInboundTasks, builder: (_, _) => const Scaffold()),
          GoRoute(path: '/blank', builder: (_, _) => const Scaffold()),
          GoRoute(
            path: RouteName.warehouseProductionFinishedBatchStockIn,
            builder: (_, _) => ProductionFinishedBatchStockInPage(
              targets: [_task('doc-a'), _task('doc-b')],
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      var table = tester
          .widget<MasterDataTableView<ProductionFinishedInboundTask>>(
            find.byKey(const Key('production-finished-batch-stock-in-table')),
          );
      table.onSelectedIdsChanged!({'doc-a'});
      await tester.pumpAndSettle();
      Future<void> submit() async {
        await tester.tap(
          find.byKey(const Key('production-finished-batch-confirm')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认批量入库'));
        await tester.pumpAndSettle();
      }

      await submit();
      final saved = container.read(formDraftsProvider).single;
      expect(saved.hasUnknownSubmission, isTrue);
      expect(saved.data['selectedDocumentIds'], ['doc-a']);
      final originalKey = saved.data['idempotencyKey'];
      expect(originalKey, startsWith('finished-in-batch-'));
      table = tester.widget<MasterDataTableView<ProductionFinishedInboundTask>>(
        find.byKey(const Key('production-finished-batch-stock-in-table')),
      );
      table.onSelectedIdsChanged!({'doc-b'});
      await tester.pumpAndSettle();
      expect(
        container.read(formDraftsProvider).single.data['selectedDocumentIds'],
        ['doc-a'],
      );
      router.go('/blank');
      await tester.pumpAndSettle();
      router.go(saved.resumeLocation);
      await tester.pumpAndSettle();
      await submit();
      expect(api.posts.length, 2);
      expect(api.posts[0].body, api.posts[1].body);
      expect(api.posts[1].body['idempotencyKey'], originalKey);
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'return batch interrupted second command resumes pending only with original warehouse',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api();
      final container = _container(api);
      addTearDown(container.dispose);
      await container.read(masterNameServiceProvider).ensureLoaded();
      final router = GoRouter(
        initialLocation: '/warehouse/material-returns/batch-receive',
        routes: [
          GoRoute(
            path: RouteName.warehouseTasks,
            builder: (_, _) => const Scaffold(),
          ),
          GoRoute(path: '/blank', builder: (_, _) => const Scaffold()),
          GoRoute(
            path: '/warehouse/material-returns/batch-receive',
            builder: (_, _) => const WarehouseMaterialReturnBatchReceivePage(
              documentIds: ['return-a', 'return-b'],
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      for (final id in ['return-a', 'return-b']) {
        tester
            .widget<UtenDropdownField>(
              find.byKey(ValueKey('material-return-batch-warehouse-$id')),
            )
            .onChanged('normal');
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认批量收料(2)'));
      await tester.pumpAndSettle();
      final saved = container.read(formDraftsProvider).single;
      expect(saved.hasUnknownSubmission, isTrue);
      expect(
        (saved.data['rows'] as List).cast<Map<String, dynamic>>().first['done'],
        isTrue,
      );
      expect(saved.data['pendingDocumentId'], 'return-b');
      router.go('/blank');
      await tester.pumpAndSettle();
      router.go(saved.resumeLocation);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(
                const ValueKey('material-return-batch-warehouse-return-b'),
              ),
            )
            .value,
        'normal',
      );
      await tester.tap(find.text('确认批量收料(1)'));
      await tester.pumpAndSettle();
      expect(
        api.posts
            .map((post) => post.path)
            .where((path) => path.contains('return-a'))
            .length,
        1,
      );
      expect(api.posts[1].body, api.posts[2].body);
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
