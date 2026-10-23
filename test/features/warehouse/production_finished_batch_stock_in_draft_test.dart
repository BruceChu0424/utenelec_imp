import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_batch_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/repositories/production_finished_inbound_task_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

const _originalKey = 'finished-in-batch-original';
const _itemDocuments = {'item-a': 'doc-a', 'item-b': 'doc-b'};
const _tableKey =
    'features.warehouse.pages.production_finished_batch_stock_in_page.ProductionFinishedBatchStockInPageState._buildTable.1';

class _SavedLayout extends PlatformTableLayoutNotifier {
  _SavedLayout(this.seed) : super(_tableKey);
  final PlatformTableLayout seed;
  @override
  PlatformTableLayout build() => seed;
}

Map<String, dynamic> _task(String id) => {
  'taskId': id,
  'taskStage': 'FINAL_COUNT',
  'documentId': id,
  'documentNo': 'IN-$id',
  'documentDate': '2026-10-22T00:00:00Z',
  'createdAt': '2026-10-22T00:00:00Z',
  'lineCount': 1,
  'pendingQty': 10,
  'residualTask': false,
};

Map<String, dynamic> _scopedDraft() => {
  'documentIds': ['doc-a', 'doc-b'],
  'selectedDocumentIds': ['doc-a'],
  'fingerprint': 'doc-a#item-a',
  'idempotencyKey': _originalKey,
  'uncertain': true,
  'selectedItemIds': ['item-a', 'item-b'],
  'selectedItemDocuments': _itemDocuments,
  'targets': [_task('doc-a'), _task('doc-b')],
};

void main() {
  Future<FormDraftMixin<ProductionFinishedBatchStockInPage>> pumpPage(
    WidgetTester tester,
    _FinishedRepository repository, {
    List<String>? items = const ['item-b', 'item-a'],
    Map<String, String> itemDocuments = _itemDocuments,
    PlatformTableLayout? layout,
    TableColumnProjectionController? projection,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final page = ProductionFinishedBatchStockInPage(
      targets: [
        _task('doc-a'),
        _task('doc-b'),
      ].map(ProductionFinishedInboundTask.fromJson).toList(),
      selectedItemIds: items,
      selectedItemDocuments: itemDocuments,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(repository.api),
          apiBaseUrlProvider.overrideWithValue('http://finished-test/api'),
          authenticatedScopeProvider.overrideWithValue(null),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({Perm.stockDocApprove}),
          isSuperAdminProvider.overrideWithValue(false),
          if (layout != null)
            platformTableLayoutProvider(
              _tableKey,
            ).overrideWith(() => _SavedLayout(layout)),
          productionFinishedInboundTaskRepositoryProvider.overrideWithValue(
            repository,
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: projection == null
              ? page
              : TableColumnProjectionScope(controller: projection, child: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state(find.byType(ProductionFinishedBatchStockInPage))
        as FormDraftMixin<ProductionFinishedBatchStockInPage>;
  }

  testWidgets('成品批量旧偏好缺少新状态列时，实际前缀恢复状态单号且保留宽度显隐', (tester) async {
    final projection = TableColumnProjectionController();
    addTearDown(projection.dispose);
    await pumpPage(
      tester,
      _FinishedRepository(),
      projection: projection,
      layout: const PlatformTableLayout(
        order: ['taskNo', 'goodsSummary', 'planNo'],
        hidden: {'planNo'},
        widths: {'taskNo': 287},
      ),
    );
    final columns = projection.resolve(_tableKey)!.columns;
    expect(columns.take(2).map((column) => column.sourceKey), [
      'status',
      'taskNo',
    ]);
    expect(
      columns.map((column) => column.sourceKey),
      isNot(contains('planNo')),
    );
    expect(
      columns.singleWhere((column) => column.sourceKey == 'taskNo').width,
      287,
    );
    expect(tester.takeException(), isNull);
  });

  Future<void> retry(WidgetTester tester, {int? expectedItems}) async {
    await tester.tap(
      find.byKey(const Key('production-finished-batch-confirm')),
    );
    await tester.pumpAndSettle();
    if (expectedItems != null) {
      expect(
        find.textContaining('仅点收本次所选 $expectedItems 项明细，未选明细继续保留待点收。'),
        findsOneWidget,
      );
    }
    await tester.tap(find.text('确认批量入库'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'unknown scoped acceptance restores mapping and replays only the original items with the original key',
    (tester) async {
      final repository = _FinishedRepository();
      final page = await pumpPage(tester, repository);
      await page.restoreFormDraft(_scopedDraft());
      await tester.pumpAndSettle();
      final restored = page.captureFormDraft();
      expect(restored['selectedItemDocuments'], _itemDocuments);
      expect(restored['selectedDocumentIds'], ['doc-a']);
      expect(restored['fingerprint'], 'doc-a#item-a');
      expect(restored['idempotencyKey'], _originalKey);
      final route = Uri.parse(page.formDraftSpec.route);
      expect(route.queryParameters['itemIds'], 'item-a,item-b');
      expect(
        jsonDecode(route.queryParameters['itemDocuments']!),
        _itemDocuments,
      );

      final table = tester
          .widget<MasterDataTableView<ProductionFinishedInboundTask>>(
            find.byType(MasterDataTableView<ProductionFinishedInboundTask>),
          );
      expect(table.columns.take(2).map((column) => column.key), [
        'status',
        'taskNo',
      ]);
      final status = table.columns.first;
      expect(
        status.value(
          table.items.firstWhere((task) => task.documentId == 'doc-a'),
        ),
        '结果待核对',
      );
      expect(
        status.value(
          table.items.firstWhere((task) => task.documentId == 'doc-b'),
        ),
        '待点收',
      );
      table.onSelectedIdsChanged!({'doc-b'});
      await tester.pump();
      expect(page.captureFormDraft()['selectedDocumentIds'], ['doc-a']);
      await retry(tester, expectedItems: 1);
      await retry(tester, expectedItems: 1);
      expect(repository.commands, [
        {
          'documentIds': ['doc-a'],
          'itemIds': ['item-a'],
          'idempotencyKey': _originalKey,
        },
        {
          'documentIds': ['doc-a'],
          'itemIds': ['item-a'],
          'idempotencyKey': _originalKey,
        },
      ]);
      expect(page.captureFormDraft()['uncertain'], isTrue);
    },
  );

  testWidgets(
    'missing, incomplete or foreign mappings reject restoration without adopting a changed command',
    (tester) async {
      final repository = _FinishedRepository();
      final page = await pumpPage(tester, repository);
      for (final mapping in <Object?>[
        null,
        <String, String>{},
        {'item-a': 'doc-a'},
        {'item-a': 'doc-a', 'item-b': 'outside'},
        {'item-a': 'doc-a', 'item-b': 'doc-b', 'extra': 'doc-a'},
      ]) {
        await expectLater(
          page.restoreFormDraft({
            ..._scopedDraft(),
            'selectedItemDocuments': mapping,
          }),
          throwsFormatException,
        );
        expect(page.captureFormDraft()['idempotencyKey'], isNull);
        expect(page.captureFormDraft()['selectedDocumentIds'], [
          'doc-a',
          'doc-b',
        ]);
      }
      await expectLater(
        page.restoreFormDraft({..._scopedDraft(), 'selectedItemIds': null}),
        throwsFormatException,
      );
      await expectLater(
        page.restoreFormDraft({
          ..._scopedDraft(),
          'selectedItemIds': <String>[],
        }),
        throwsFormatException,
      );
      expect(repository.commands, isEmpty);
    },
  );

  testWidgets(
    'route and payload mapping disagreement cannot revive an unknown request',
    (tester) async {
      final repository = _FinishedRepository();
      final page = await pumpPage(tester, repository);
      await expectLater(
        page.restoreFormDraft({
          ..._scopedDraft(),
          'selectedItemDocuments': {'item-a': 'doc-b', 'item-b': 'doc-a'},
        }),
        throwsFormatException,
      );
      expect(page.captureFormDraft()['idempotencyKey'], isNull);
      expect(repository.commands, isEmpty);
    },
  );

  testWidgets(
    'an explicit item scope without route ownership cannot become document scope during restoration',
    (tester) async {
      final repository = _FinishedRepository();
      final page = await pumpPage(tester, repository, itemDocuments: const {});
      await expectLater(
        page.restoreFormDraft(_scopedDraft()),
        throwsFormatException,
      );
      expect(repository.commands, isEmpty);
      expect(page.captureFormDraft()['idempotencyKey'], isNull);
    },
  );

  testWidgets(
    'legacy document scope restores without inventing an item scope or changing its unknown key',
    (tester) async {
      final repository = _FinishedRepository();
      final page = await pumpPage(
        tester,
        repository,
        items: null,
        itemDocuments: const {},
      );
      final draft = _scopedDraft()
        ..remove('selectedItemIds')
        ..remove('selectedItemDocuments')
        ..['selectedDocumentIds'] = ['doc-a', 'doc-b']
        ..['fingerprint'] = 'doc-a|doc-b';
      await page.restoreFormDraft(draft);
      await tester.pumpAndSettle();
      expect(page.captureFormDraft()['selectedItemDocuments'], isEmpty);
      expect(
        Uri.parse(page.formDraftSpec.route).queryParameters,
        isNot(contains('itemIds')),
      );
      expect(
        Uri.parse(page.formDraftSpec.route).queryParameters,
        isNot(contains('itemDocuments')),
      );
      await retry(tester);
      expect(repository.commands.single, {
        'documentIds': ['doc-a', 'doc-b'],
        'itemIds': null,
        'idempotencyKey': _originalKey,
      });
    },
  );
  testWidgets('legacy与精确点收草稿都不能替换原路由单据或在失败后留下半份提交身份', (tester) async {
    for (final scoped in [false, true]) {
      final repository = _FinishedRepository();
      final page = await pumpPage(
        tester,
        repository,
        items: scoped ? const ['item-a', 'item-b'] : null,
        itemDocuments: scoped ? _itemDocuments : const {},
      );
      for (final change in <Map<String, dynamic>>[
        {
          'documentIds': ['doc-a', 'foreign'],
        },
        {
          'targets': [_task('doc-a'), _task('foreign')],
        },
        {
          'targets': [_task('doc-a')],
        },
        {
          'targets': [_task('doc-a'), _task('doc-b'), _task('doc-a')],
        },
      ]) {
        final snapshot = {
          ..._scopedDraft(),
          if (!scoped) 'selectedItemIds': null,
          if (!scoped) 'selectedItemDocuments': <String, String>{},
          ...change,
        };
        await expectLater(
          page.restoreFormDraft(snapshot),
          throwsFormatException,
        );
        expect(page.captureFormDraft()['documentIds'], ['doc-a', 'doc-b']);
        expect(page.captureFormDraft()['selectedDocumentIds'], [
          'doc-a',
          'doc-b',
        ]);
        expect(page.captureFormDraft()['idempotencyKey'], isNull);
        expect(repository.commands, isEmpty);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}

class _ReadApi extends ApiClient {
  _ReadApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

class _FinishedRepository extends ProductionFinishedInboundTaskRepository {
  _FinishedRepository() : super(_ReadApi());
  final commands = <Map<String, Object?>>[];

  @override
  Future<({int confirmedCount, bool replay, Set<String> confirmedDocumentIds})>
  confirmAll({
    required List<String> documentIds,
    required String idempotencyKey,
    List<String>? itemIds,
  }) async {
    commands.add({
      'documentIds': List<String>.of(documentIds),
      'itemIds': itemIds == null ? null : List<String>.of(itemIds),
      'idempotencyKey': idempotencyKey,
    });
    throw ApiException('NETWORK_TIMEOUT', '结果暂未确认，请保持原选择重试');
  }
}
