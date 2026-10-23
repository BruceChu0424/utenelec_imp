import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'inventory-test-user'),
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  const permissions = {Perm.stockView, Perm.goodsView, Perm.goodsEdit};

  Future<ProviderContainer> pumpPage(
    WidgetTester tester,
    _LocationApi api, {
    Set<String> grants = permissions,
    Size size = const Size(2200, 1000),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          authenticatedScopeProvider.overrideWith(
            (ref) => ref.watch(_identity),
          ),
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(grants),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const InstantInventoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(InstantInventoryPage)),
    );
  }

  MasterInlineEditController<InstantInventoryRow> controller(
    WidgetTester tester,
  ) => tester
      .widget<MasterInlineEditActions<InstantInventoryRow>>(
        find.byType(MasterInlineEditActions<InstantInventoryRow>),
      )
      .controller;

  Future<void> editPlace(WidgetTester tester, String value) async {
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    final activation = find
        .byKey(const ValueKey('inline-activate-g1-stockPlace'))
        .first;
    await tester.ensureVisible(activation);
    await tester.tap(activation);
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'A-01');
    await tester.enterText(field, value);
    await tester.pump();
  }

  testWidgets(
    'stock viewing never requests goods capabilities or grants write access',
    (tester) async {
      final api = _LocationApi();
      await pumpPage(tester, api, grants: {Perm.stockView});
      expect(find.text('编辑模式'), findsNothing);
      expect(api.goodsReads, 0);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'location saves once per goods with the original version and leaves balances untouched',
    (tester) async {
      final api = _LocationApi(twoColors: true);
      await pumpPage(tester, api);
      expect(api.goodsReads, 0);
      await editPlace(tester, 'B-02');
      expect(
        api.goodsReads,
        1,
        reason: 'two color rows share one master snapshot',
      );
      expect(find.text('保存 1 行修改'), findsOneWidget);
      final table = tester.widget<MasterDataTableView<InstantInventoryRow>>(
        find.byType(MasterDataTableView<InstantInventoryRow>),
      );
      expect(table.onRowTap, isNull);
      expect(
        table.columns
            .singleWhere((c) => c.key == 'qty')
            .value(table.items.first),
        '10 个',
      );
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(api.writes, [
        {
          'path': '/master/inline-edit/goods/g1',
          'body': {
            'expected': {'version': 7},
            'changes': {'stockPlace': 'B-02'},
          },
        },
      ]);
      expect(api.stockPlace, 'B-02');
      expect(api.qty, 10);
      expect(controller(tester).dirty, isFalse);
      expect(find.text('B-02'), findsWidgets);
    },
  );

  testWidgets(
    'location patch cannot adopt another identity during request capture or revive on A-B-A',
    (tester) async {
      final api = _GatedLocationApi();
      final container = await pumpPage(tester, api);
      await editPlace(tester, 'B-02');
      await tester.tap(find.text('保存 1 行修改'));
      for (var frame = 0; frame < 20 && !api.capturing; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(api.capturing, isTrue);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'other-user',
      );
      await tester.pump();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'inventory-test-user',
      );
      await tester.pump();
      api.gate.complete();
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(api.stockPlace, 'A-01');
      expect(api.qty, 10);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'warehouse editor uses the goods UUID picker and never changes the stock query warehouse',
    (tester) async {
      final api = _LocationApi();
      await pumpPage(tester, api);
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      final activation = find.byKey(
        const ValueKey('inline-activate-g1-owningWarehouseId'),
      );
      await tester.ensureVisible(activation);
      await tester.tap(activation);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '原仓库'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-w2')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      final body = api.writes.single['body'] as Map;
      expect(body['changes'], {'owningWarehouseId': 'w2'});
      expect(
        api.inventoryQueries.every((query) => query['warehouseId'] == null),
        isTrue,
      );
      expect(api.qty, 10);
    },
  );

  testWidgets('stale location or a read-only goods row remains read-only', (
    tester,
  ) async {
    for (final api in [
      _LocationApi(staleLocation: true),
      _LocationApi(writable: false),
      _LocationApi(missingVersion: true),
      _LocationApi(failedCapability: true),
    ]) {
      await pumpPage(tester, api);
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('inline-activate-g1-stockPlace')),
        findsNothing,
      );
      expect(find.textContaining('资料不可编辑或已变化'), findsOneWidget);
      expect(api.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'a server version conflict keeps the draft and does not retry with a newer version',
    (tester) async {
      final api = _LocationApi(conflict: true);
      await pumpPage(tester, api);
      await editPlace(tester, 'B-02');
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(find.text('货品已有后续修改，请刷新后重新编辑'), findsOneWidget);
      expect(controller(tester).dirty, isTrue);
      expect(api.writes.length, 1);
      expect(api.goodsReads, 1);
      expect(api.stockPlace, 'A-01');
      expect(api.qty, 10);
    },
  );

  testWidgets(
    'canceling refresh preserves the draft and discarding sends no write',
    (tester) async {
      final api = _LocationApi();
      await pumpPage(tester, api);
      await editPlace(tester, 'B-02');
      final reads = api.inventoryQueries.length;
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(controller(tester).dirty, isTrue);
      expect(api.inventoryQueries.length, reads);
      await tester.tap(find.text('取消编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.text('编辑模式'), findsOneWidget);
      expect(api.writes, isEmpty);
      expect(api.stockPlace, 'A-01');
    },
  );

  testWidgets(
    'permission changes discard location drafts before further writes',
    (tester) async {
      final api = _LocationApi();
      final container = await pumpPage(tester, api);
      await editPlace(tester, 'B-02');
      container.updateOverrides([
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        sharedPreferencesProvider.overrideWithValue(
          container.read(sharedPreferencesProvider),
        ),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue({Perm.stockView}),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('编辑模式'), findsNothing);
      expect(find.text('保存 1 行修改'), findsNothing);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets('location actions fit narrow, dark and large text layouts', (
    tester,
  ) async {
    final api = _LocationApi();
    await pumpPage(
      tester,
      api,
      size: const Size(375, 812),
      textScale: 1.6,
      brightness: Brightness.dark,
    );
    expect(find.text('编辑模式'), findsOneWidget);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    expect(find.text('取消编辑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _LocationApi extends ApiClient {
  _LocationApi({
    this.twoColors = false,
    this.staleLocation = false,
    this.writable = true,
    this.conflict = false,
    this.missingVersion = false,
    this.failedCapability = false,
  }) : super(Dio());
  final bool twoColors;
  final bool staleLocation;
  final bool writable;
  final bool conflict;
  final bool missingVersion;
  final bool failedCapability;
  int goodsReads = 0;
  int version = 7;
  String stockPlace = 'A-01';
  String warehouseId = 'w1';
  final qty = 10;
  final writes = <Map<String, Object?>>[];
  final inventoryQueries = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('warehouses/dict')
      ? [
          {'id': 'w1', 'name': '原仓库', 'code': 'W1', 'selectableForNew': true},
          {'id': 'w2', 'name': '新仓库', 'code': 'W2', 'selectableForNew': true},
        ]
      : [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/goods/g1')) {
      goodsReads++;
      if (failedCapability) {
        throw ApiException('FORBIDDEN', '无权读取当前货品');
      }
      return {
        'id': 'g1',
        'version': missingVersion ? null : version,
        'writable': writable,
        'stockPlace': staleLocation ? 'C-03' : stockPlace,
        'owningWarehouseId': warehouseId,
      };
    }
    if (!path.endsWith('/instant-inventory')) return {};
    inventoryQueries.add(Map<String, dynamic>.from(query ?? {}));
    return {
      'items': [
        for (final color in [null, if (twoColors) 'red'])
          {
            'goodsId': 'g1',
            'colorId': color,
            'name': '螺丝',
            'stockPlace': stockPlace,
            'owningWarehouseId': warehouseId,
            'owningWarehouseName': warehouseId == 'w1' ? '原仓库' : '新仓库',
            'qty': qty,
            'unitName': '个',
          },
      ],
      'page': 1,
      'size': 20,
      'total': twoColors ? 2 : 1,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    writes.add({'path': path, 'body': body});
    if (conflict) throw ApiException('CONFLICT', '货品已有后续修改，请刷新后重新编辑');
    final changes = (body as Map)['changes'] as Map;
    if (changes.containsKey('stockPlace')) {
      stockPlace = changes['stockPlace'] as String;
    }
    if (changes.containsKey('owningWarehouseId')) {
      warehouseId = changes['owningWarehouseId'] as String;
    }
    version++;
    return {};
  }
}

class _GatedLocationApi extends _LocationApi {
  final gate = Completer<void>();
  bool capturing = false;
  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) async {
    capturing = true;
    await gate.future;
    return super.captureRequestScope(isCurrent: isCurrent);
  }
}
