import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_prep_tab.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void retire() => state++;
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <(String, Map<String, dynamic>)>[];
  final writes = <Object?>[];
  Completer<void>? tail;
  bool holdTail = false;
  bool failTail = false;
  bool changeRevision = false;
  String version = 'A';

  Map<String, dynamic> _summary(int i) => {
    'productGoodsId': 'product-$i',
    'productCode': 'P$i',
    'productName': i == 1000 ? '末尾中文水杯' : '产品$i',
    'productSpec': '原规格',
    'legacyMaterial': '原材质',
    'recentRuns': 1,
    'status': 'PENDING',
    'goodsWeightGramsExact': '2.5',
    'hasOrderBom': false,
    'bomRowCount': 2,
    'choiceRowCount': 0,
  };

  Map<String, dynamic> _meta(
    int page,
    int size,
    int total,
    String resource, {
    String? capturedVersion,
  }) => {
    'page': page,
    'size': size,
    'total': total,
    'totalPages': (total + size - 1) ~/ size,
    'readScopeVersion': 'auth-A',
    'readDataVersion': 'domain-${capturedVersion ?? version}',
    'readSnapshotRevision': '$resource-${capturedVersion ?? version}',
    'scope': 'all',
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final q = Map<String, dynamic>.of(query ?? const {});
    reads.add((path, q));
    final page = q['page'] as int? ?? 1;
    final size = q['size'] as int? ?? 100;
    if (path.endsWith('/preparation/summaries')) {
      final capturedVersion = version;
      if (page == 2 && holdTail) {
        holdTail = false;
        await tail!.future;
      }
      if (page == 2 && failTail) throw ApiException('NETWORK', '尾批读取失败');
      return {
        ..._meta(page, size, 1001, 'summary', capturedVersion: capturedVersion),
        if (page == 2 && changeRevision)
          'readSnapshotRevision': 'changed-same-count',
        'windowAsOf': '2026-11-06T12:00:00Z',
        'items': [
          for (var i = (page - 1) * size; i < page * size && i < 1001; i++)
            _summary(i),
        ],
      };
    }
    if (path.contains('/preparation/products/')) {
      final id = path.split('/').last;
      return {
        ..._meta(1, 1000, 1001, 'summary'),
        'windowAsOf': '2026-11-06T12:00:00Z',
        'rows': [
          for (var i = 0; i < 2; i++)
            {
              'productGoodsId': id,
              'productName': id == 'product-1000' ? '末尾中文水杯' : id,
              'productCode': id,
              'materialGoodsId': 'material-$i',
              'materialName': '原料$i',
              'bomItemId': 'bom-$id-$i',
              'unitWeightGrams': i == 0 ? 1.5 : 3.25,
              'status': 'WEIGHED',
              'materialSource': 'BOM',
              'goodsWeightGrams': 2.5,
            },
        ],
      };
    }
    if (path.endsWith('/preparation/material-options')) {
      return {
        ..._meta(page, size, 1001, 'options'),
        'items': [
          for (var i = (page - 1) * size; i < page * size && i < 1001; i++)
            {
              'goodsId': 'material-$i',
              'name': i == 1000 ? '末尾中文颗粒' : '原料$i',
              'code': 'M$i',
              'unitName': 'kg',
            },
        ],
      };
    }
    // The previous production reader consumes this real legacy prefix. The
    // regression must fail there rather than pretending that prefix is all.
    if (path.endsWith('/preparation')) {
      return {
        'totalProducts': 1001,
        'rows': [for (var i = 0; i < 300; i++) _summary(i)],
      };
    }
    throw ApiException('UNEXPECTED', path);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(body);
    return {'warnings': <String>[]};
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api, {
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view
    ..physicalSize = const Size(1600, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        workshopMaterialRepositoryProvider.overrideWithValue(
          WorkshopMaterialRepository(api),
        ),
        sharedPreferencesProvider.overrideWithValue(prefs),
        exportContextEpochProvider.overrideWith(_Epoch.new),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: WmPrepTab(workshopId: 'workshop-A')),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return ProviderScope.containerOf(tester.element(find.byType(WmPrepTab)));
}

Finder get _table => find.byWidgetPredicate(
  (w) =>
      w is MasterDataTableView<Map<String, dynamic>> &&
      w.tableKey == 'workshop.material.preparation.complete-summary',
);

MasterDataTableView<Map<String, dynamic>> _summary(WidgetTester tester) =>
    tester.widget(_table);

void main() {
  testWidgets(
    'summary refresh retains dirty controllers but changed domain retires their save authority',
    (tester) async {
      final api = _Api();
      await _mount(tester, api);
      await tester.tap(find.byKey(const ValueKey('wm-summary-open-product-0')));
      await tester.pumpAndSettle();
      UtenEditableGrid<WmPrepRow> editor() =>
          tester.widget(find.byKey(const Key('wm-prep-grid')));
      final originalController = editor().controller;
      final originalRow = originalController.rows.first;
      originalRow.grams.text = '1.234567';
      await tester.tap(find.byType(UtenRefreshButton));
      await tester.pumpAndSettle();
      expect(editor().controller, same(originalController));
      expect(editor().controller.rows.first, same(originalRow));
      expect(originalRow.grams.text, '1.234567');
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('wm-prep-save')))
            .onPressed,
        isNotNull,
      );
      api.version = 'B';
      await tester.tap(find.byType(UtenRefreshButton));
      await tester.pumpAndSettle();
      expect(editor().controller, same(originalController));
      expect(editor().controller.rows.first, same(originalRow));
      expect(originalRow.grams.text, '1.234567');
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('wm-prep-save')))
            .onPressed,
        isNull,
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('wm-prep-grams-product-0')),
      );
      expect(field.enabled, isFalse);
      expect(api.writes, isEmpty);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'all1001 summaries load once, Chinese tail filters locally and only explicit product opens all its editable rows',
    (tester) async {
      final api = _Api();
      await _mount(tester, api);
      final tableLengths = [
        for (final element
            in find
                .byWidgetPredicate((w) => w is MasterDataTableView<Object?>)
                .evaluate())
          if (element.widget case final MasterDataTableView<Object?> table)
            table.items.length,
      ];
      expect(tableLengths, isNotEmpty);
      expect(
        tableLengths.reduce((a, b) => a > b ? a : b),
        1001,
        reason:
            'the selected authorized scope cannot be a legacy300 product prefix',
      );
      expect(_table, findsOneWidget);
      expect(_summary(tester).items, hasLength(1001));
      expect(_summary(tester).showPaginationControls, isFalse);
      expect(_summary(tester).onLoadMore, isNull);
      expect(find.byType(UtenEditableGrid<WmPrepRow>), findsNothing);
      expect(api.reads, hasLength(2));
      expect(api.reads[1].$2['readSnapshotRevision'], 'summary-A');
      expect(api.reads[1].$2['windowAsOf'], '2026-11-06T12:00:00Z');
      expect(api.reads.every((r) => r.$2['size'] == 1000), isTrue);
      final body = find.descendant(
        of: _table,
        matching: find.byWidgetPredicate(
          (w) =>
              w is UtenPageScrollbarSource &&
              w.debugLabel == 'master-table-body',
        ),
      );
      expect(body, findsOneWidget);
      final controller = tester
          .widget<UtenPageScrollbarSource>(body)
          .controller;
      expect(controller.position.maxScrollExtent, greaterThan(0));
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      // Visible-row measurement can update the previous estimated extent.
      // Finish the movement with the same real body gesture a user makes.
      await tester.dragFrom(tester.getRect(body).center, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('末尾中文水杯'), findsWidgets);
      expect(
        api.reads,
        hasLength(2),
        reason: 'scroll is local presentation only',
      );
      await tester.tap(
        find.byKey(const ValueKey('master-column-filter-productName')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '末尾中文',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('末尾中文水杯'), findsWidgets);
      expect(
        api.reads,
        hasLength(2),
        reason: 'Chinese filtering uses the accepted complete summary',
      );
      final open = find.byKey(const ValueKey('wm-summary-open-product-1000'));
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      expect(open.hitTestable(), findsOneWidget);
      await tester.tap(open);
      await tester.pumpAndSettle();
      final grid = tester.widget<UtenEditableGrid<WmPrepRow>>(
        find.byKey(const Key('wm-prep-grid')),
      );
      expect(grid.controller.rows, hasLength(2));
      expect(
        grid.controller.rows.every(
          (row) => row.source.productGoodsId == 'product-1000',
        ),
        isTrue,
      );
      expect(api.reads.where((r) => r.$1.contains('/products/')), hasLength(1));
      expect(
        api.reads.where((r) => r.$1.endsWith('/material-options')),
        hasLength(2),
      );
      expect(
        api.reads
            .where((r) => r.$1.endsWith('/material-options'))
            .first
            .$2
            .containsKey('readSnapshotRevision'),
        isFalse,
      );
      expect(
        api.reads
            .where((r) => r.$1.endsWith('/material-options'))
            .last
            .$2['readSnapshotRevision'],
        'options-A',
      );
      grid.controller.rows.first.grams.text = '2.125';
      await tester.tap(find.byKey(const Key('wm-prep-save')));
      await tester.pumpAndSettle();
      final bodySent = api.writes.single! as Map;
      final rows = bodySent['rows'] as List;
      expect(
        rows,
        hasLength(2),
        reason: 'the edited product retains its complete second material',
      );
      expect((rows[0] as Map)['unitWeightGrams'], 2.125);
      expect((rows[1] as Map)['unitWeightGrams'], 3.25);
      expect(tester.takeException(), isNull);
    },
  );

  for (final changed in [false, true]) {
    testWidgets(
      'tail ${changed ? 'same-count revision change' : 'failure'} ends loading without a prefix and explicit retry returns every summary',
      (tester) async {
        final api = _Api()
          ..failTail = !changed
          ..changeRevision = changed;
        await _mount(tester, api);
        expect(_summary(tester).items, isEmpty);
        expect(_summary(tester).error, isNotNull);
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(api.writes, isEmpty);
        api
          ..failTail = false
          ..changeRevision = false;
        await tester.tap(find.text('重试').first);
        await tester.pumpAndSettle();
        expect(_summary(tester).items, hasLength(1001));
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'owner retirement releases a held tail, accepts a real new read and rejects the late old result',
    (tester) async {
      final gate = Completer<void>();
      final api = _Api()
        ..tail = gate
        ..holdTail = true;
      final container = await _mount(tester, api, settle: false);
      for (var i = 0; i < 30 && api.reads.length < 2; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(api.reads, hasLength(2));
      (container.read(exportContextEpochProvider.notifier) as _Epoch).retire();
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(_summary(tester).items, isEmpty);
      await tester.pumpAndSettle();
      api.version = 'B';
      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      expect(_summary(tester).error, isNull, reason: api.reads.toString());
      expect(_summary(tester).items, hasLength(1001));
      final accepted = _summary(tester).items;
      gate.complete();
      await tester.pumpAndSettle();
      expect(_summary(tester).items, same(accepted));
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
