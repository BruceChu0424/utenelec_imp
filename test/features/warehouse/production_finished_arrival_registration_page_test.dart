import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/providers/production_finished_inbound_task_count_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _reportId = '20000000-0000-0000-0000-000000000001';

void main() {
  testWidgets(
    'arrival registration is operable at 375px and posts exact warehouse places',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ArrivalRegistrationApi();
      await _openPage(tester, api: api, canRegister: true);

      expect(find.text('登记成品仓与库位'), findsOneWidget);
      expect(find.text('第 1 步：仓库登记到货位置'), findsOneWidget);
      expect(find.text('RB202608300001'), findsOneWidget);
      expect(tester.takeException(), isNull);

      _pressSubmit(tester);
      await tester.pump();
      expect(find.text('请选择实际存放的成品仓库'), findsWidgets);

      await tester.tap(
        find.byKey(const Key('production-finished-arrival-warehouse')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('成品仓').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('production-finished-arrival-warehouse')),
            )
            .value,
        'warehouse-1',
      );
      await _revealGrid(tester);
      expect(find.text('10'), findsOneWidget);
      final placeField = find.byKey(
        const ValueKey(
          'production-finished-arrival-place-'
          '30000000-0000-0000-0000-000000000001',
        ),
      );
      expect(tester.widget<TextField>(placeField).controller?.text, isEmpty);

      _pressSubmit(tester);
      await tester.pump();
      expect(api.lastPostBody, isNull);
      expect(find.text('登记成品仓与库位'), findsOneWidget);
      final validation = find.byKey(
        const Key('production-finished-arrival-validation-error'),
      );
      expect(validation, findsOneWidget);
      expect(tester.widget<Text>(validation).data, '第 1 行必须填写库位号');

      await tester.enterText(placeField, ' CP-A-01 ');
      _pressSubmit(tester);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('open-arrival-registration')),
        findsOneWidget,
      );
      expect(
        api.lastPostPath,
        '/warehouse/production-finished-in/arrival-registrations/$_reportId',
      );
      expect(api.lastPostBody?['warehouseId'], 'warehouse-1');
      expect(api.lastPostBody?['items'], const [
        {
          'reportItemId': '30000000-0000-0000-0000-000000000001',
          'place': 'CP-A-01',
        },
      ]);
      expect(
        (api.lastPostBody?['idempotencyKey'] as String?)?.length,
        greaterThanOrEqualTo(8),
      );
      expect(api.rememberRequests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view-only arrival task exposes no editable promise', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      registered: true,
      warehouseId: 'warehouse-1',
      place: 'CP-A-01',
    );
    await _openPage(tester, api: api, canRegister: false);
    await _revealGrid(tester);

    expect(
      find.byKey(const Key('production-finished-arrival-submit')),
      findsNothing,
    );
    expect(find.text('该到货登记已提交，仓库和库位仅供核对。'), findsOneWidget);
    expect(
      tester
          .widget<UtenDropdownField>(
            find.byKey(const Key('production-finished-arrival-warehouse')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(
              const ValueKey(
                'production-finished-arrival-place-'
                '30000000-0000-0000-0000-000000000001',
              ),
            ),
          )
          .enabled,
      isFalse,
    );
    expect(find.text('本次登记快照'), findsOneWidget);
    expect(
      find.byKey(const Key('production-finished-arrival-remember-places')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'formal route derives permission and refreshes pending count after save',
    (tester) async {
      final api = _ArrivalRegistrationApi();
      final router = GoRouter(
        initialLocation: RouteName.warehouseProductionFinishedInboundTasks,
        routes: [
          GoRoute(
            path: RouteName.warehouseProductionFinishedInboundTasks,
            builder: (_, _) => const _ArrivalRouteQueue(),
          ),
          GoRoute(
            path: RouteName.warehouseProductionFinishedArrivalRegistration,
            builder: (_, state) => ProductionFinishedArrivalRegistrationPage(
              reportId: state.pathParameters['reportId'] ?? '',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.stockDocView,
              Perm.stockDocApprove,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.countRequests, 1);

      await tester.tap(find.byKey(const Key('open-formal-arrival-route')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('production-finished-arrival-submit')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('production-finished-arrival-warehouse')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('成品仓').last);
      await tester.pumpAndSettle();
      await _revealGrid(tester);
      await tester.enterText(
        find.byKey(
          const ValueKey(
            'production-finished-arrival-place-'
            '30000000-0000-0000-0000-000000000001',
          ),
        ),
        'CP-A-01',
      );
      await tester.tap(
        find.byKey(const Key('production-finished-arrival-submit')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('open-formal-arrival-route')),
        findsOneWidget,
      );
      expect(api.countRequests, 2);
      expect(api.lastPostBody?['warehouseId'], 'warehouse-1');
    },
  );

  testWidgets('place stays disabled until warehouse suggestions are ready', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(placeHint: 'GLOBAL-A-01');
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    final beforeSelection = tester.widget<TextField>(placeField);
    expect(beforeSelection.enabled, isFalse);
    expect(beforeSelection.controller?.text, isEmpty);
    expect(beforeSelection.decoration?.hintText, '请先选择成品仓');
    expect(find.text('请先选择成品仓'), findsWidgets);
    expect(_requiredPlaceHeader(), findsNothing);
    expect(find.byType(RequiredCellFrame), findsNothing);

    await _revealWarehouse(tester);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);

    final afterSelection = tester.widget<TextField>(placeField);
    expect(afterSelection.enabled, isTrue);
    expect(afterSelection.controller?.text, 'GLOBAL-A-01');
    expect(find.text('货品主档通用建议'), findsOneWidget);
    expect(_requiredPlaceHeader(), findsWidgets);
    expect(find.byType(RequiredCellFrame), findsOneWidget);
  });

  testWidgets('global default stays editable and manual input changes source', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(placeHint: 'GLOBAL-A-01');
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'GLOBAL-A-01',
    );
    expect(find.text('货品主档通用建议'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(
              const Key('production-finished-arrival-remember-places'),
            ),
          )
          .value,
      isTrue,
    );

    await tester.enterText(placeField, 'MANUAL-A-02');
    await tester.pump();
    expect(find.text('手工输入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('registration history suggestion is visible and editable', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      suggestionsByWarehouse: const {
        'warehouse-1': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'HISTORY-A-08',
            'source': 'REGISTRATION_HISTORY',
          },
        ],
      },
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'HISTORY-A-08',
    );
    expect(find.text('最近登记：同仓同货品'), findsOneWidget);

    await tester.enterText(placeField, 'MANUAL-A-09');
    await tester.pump();
    expect(find.text('手工输入'), findsOneWidget);
  });

  testWidgets('warehouse preference replaces untouched global suggestion', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      placeHint: 'GLOBAL-A-01',
      suggestionsByWarehouse: const {
        'warehouse-1': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'WH-A-09',
            'source': 'WAREHOUSE_PREFERENCE',
          },
        ],
      },
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).controller?.text, 'WH-A-09');
    expect(find.text('该仓默认'), findsOneWidget);
  });

  testWidgets('late warehouse response cannot overwrite newer warehouse', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi();
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    await _selectWarehouse(tester, '备用成品仓');
    api.completeSuggestion('warehouse-2', place: 'WH-B-02');
    await tester.pump();
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).controller?.text, 'WH-B-02');
    expect(find.text('该仓默认'), findsOneWidget);
  });

  testWidgets('manual input survives retry for the same warehouse', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi();
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.failSuggestion('warehouse-1');
    await tester.pumpAndSettle();
    await _revealGrid(tester);
    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).enabled, isTrue);
    await tester.enterText(placeField, 'MANUAL-A-07');
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('production-finished-arrival-retry-suggestions')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-retry-suggestions')),
    );
    await tester.pump();
    expect(tester.widget<TextField>(placeField).enabled, isFalse);
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'MANUAL-A-07',
    );

    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _revealGrid(tester);

    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'MANUAL-A-07',
    );
    expect(find.text('手工输入'), findsOneWidget);
  });

  testWidgets('switching warehouse discards the previous manual place', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      suggestionsByWarehouse: const {
        'warehouse-1': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'WH-A-01',
            'source': 'WAREHOUSE_PREFERENCE',
          },
        ],
        'warehouse-2': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'WH-B-02',
            'source': 'WAREHOUSE_PREFERENCE',
          },
        ],
      },
    );
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);
    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    await tester.enterText(placeField, 'MANUAL-A-07');
    await tester.pump();

    await _revealWarehouse(tester);
    await _selectWarehouse(tester, '备用成品仓', settle: true);
    await _revealGrid(tester);

    expect(tester.widget<TextField>(placeField).controller?.text, 'WH-B-02');
    expect(find.text('该仓默认'), findsOneWidget);
  });

  testWidgets('switching to none restores the goods master fallback', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi(placeHint: 'GLOBAL-A-01');
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _selectWarehouse(tester, '备用成品仓');
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).enabled, isFalse);
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'GLOBAL-A-01',
    );
    api.completeSuggestion('warehouse-2', place: null, source: 'NONE');
    await tester.pump();

    expect(tester.widget<TextField>(placeField).enabled, isTrue);
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'GLOBAL-A-01',
    );
    expect(find.text('货品主档通用建议'), findsOneWidget);
  });

  testWidgets('failed next-warehouse lookup cannot retain prior auto place', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi();
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _selectWarehouse(tester, '备用成品仓');
    api.failSuggestion('warehouse-2');
    await tester.pumpAndSettle();
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).enabled, isTrue);
    expect(tester.widget<TextField>(placeField).controller?.text, isEmpty);
    expect(find.text('暂无默认'), findsOneWidget);
  });

  testWidgets('missing row suggestion cannot retain prior warehouse value', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi(duplicateGoodsRows: true);
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _selectWarehouse(tester, '备用成品仓');
    api.completeSuggestionItems('warehouse-2', const [
      {
        'reportItemId': '30000000-0000-0000-0000-000000000001',
        'place': 'WH-B-02',
        'source': 'WAREHOUSE_PREFERENCE',
      },
    ]);
    await tester.pump();
    await _revealGrid(tester);

    expect(
      tester
          .widget<TextField>(
            _placeField('30000000-0000-0000-0000-000000000001'),
          )
          .controller
          ?.text,
      'WH-B-02',
    );
    expect(
      tester
          .widget<TextField>(
            _placeField('30000000-0000-0000-0000-000000000002'),
          )
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('remember switch off skips remember endpoint', (tester) async {
    final api = _ArrivalRegistrationApi();
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-remember-places')),
    );
    await tester.pump();
    await _revealGrid(tester);
    await tester.enterText(
      _placeField('30000000-0000-0000-0000-000000000001'),
      'CP-A-01',
    );
    _pressSubmit(tester);
    await tester.pumpAndSettle();

    expect(api.rememberRequests, 0);
    expect(find.byKey(const Key('open-arrival-registration')), findsOneWidget);
  });

  testWidgets(
    'remember conflict blocks registration for same goods and color',
    (tester) async {
      final api = _ArrivalRegistrationApi(duplicateGoodsRows: true);
      await _openPage(tester, api: api, canRegister: true);
      await _selectWarehouse(tester, '成品仓', settle: true);
      await _revealGrid(tester);
      await tester.enterText(
        _placeField('30000000-0000-0000-0000-000000000001'),
        'CP-A-01',
      );
      await tester.enterText(
        _placeField('30000000-0000-0000-0000-000000000002'),
        'CP-B-02',
      );
      _pressSubmit(tester);
      await tester.pump();

      expect(find.textContaining('同一颜色维度填写了不同库位'), findsOneWidget);
      expect(find.textContaining('关闭“同时记住”'), findsOneWidget);
      expect(api.lastPostBody, isNull);
    },
  );

  testWidgets(
    'remember failure keeps read-only retry state until retry succeeds',
    (tester) async {
      final api = _ArrivalRegistrationApi(failFirstRemember: true);
      await _openPage(tester, api: api, canRegister: true);
      await _selectWarehouse(tester, '成品仓', settle: true);
      await _revealGrid(tester);
      final placeField = _placeField('30000000-0000-0000-0000-000000000001');
      await tester.enterText(placeField, 'CP-A-01');
      _pressSubmit(tester);
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(api.rememberRequests, 1);
      expect(
        find.byKey(const Key('production-finished-arrival-remember-failure')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(placeField).enabled, isFalse);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('production-finished-arrival-refresh')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const Key('production-finished-arrival-retry-remember')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('production-finished-arrival-retry-remember')),
      );
      await tester.pumpAndSettle();
      expect(api.rememberRequests, 2);
      expect(
        find.byKey(const Key('open-arrival-registration')),
        findsOneWidget,
      );
    },
  );
}

class _ArrivalRouteQueue extends ConsumerWidget {
  const _ArrivalRouteQueue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(warehouseProductionFinishedInboundPendingCountProvider);
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open-formal-arrival-route'),
          onPressed: () => context.push(
            RoutePath.warehouseProductionFinishedArrivalRegistration(
              _reportId,
              returnTo: RouteName.warehouseProductionFinishedInboundTasks,
            ),
          ),
          child: const Text('打开登记'),
        ),
      ),
    );
  }
}

Finder _placeField(String reportItemId) =>
    find.byKey(ValueKey('production-finished-arrival-place-$reportItemId'));

Finder _requiredPlaceHeader() => find.byWidgetPredicate(
  (widget) => widget is Text && widget.textSpan?.toPlainText() == '库位号 *',
);

Future<void> _revealWarehouse(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const Key('production-finished-arrival-warehouse')),
  );
  await tester.pump();
}

Future<void> _revealGrid(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('production-finished-arrival-registration-grid')),
    320,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

Future<void> _selectWarehouse(
  WidgetTester tester,
  String label, {
  bool settle = false,
}) async {
  await tester.tap(
    find.byKey(const Key('production-finished-arrival-warehouse')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.text(label).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  if (settle) await tester.pumpAndSettle();
}

void _pressSubmit(WidgetTester tester) {
  tester
      .widget<UtenButton>(
        find.byKey(const Key('production-finished-arrival-submit')),
      )
      .onPressed!
      .call();
}

Future<void> _openPage(
  WidgetTester tester, {
  required _ArrivalRegistrationApi api,
  required bool canRegister,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('open-arrival-registration'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProductionFinishedArrivalRegistrationPage(
                      reportId: _reportId,
                      canRegister: canRegister,
                    ),
                  ),
                ),
                child: const Text('打开登记'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-arrival-registration')));
  await tester.pumpAndSettle();
}

class _ArrivalRegistrationApi extends ApiClient {
  _ArrivalRegistrationApi({
    this.registered = false,
    this.warehouseId,
    this.place,
    this.placeHint,
    this.duplicateGoodsRows = false,
    this.failFirstRemember = false,
    this.suggestionsByWarehouse = const {},
  }) : super(Dio());

  final bool registered;
  final String? warehouseId;
  final String? place;
  final String? placeHint;
  final bool duplicateGoodsRows;
  final bool failFirstRemember;
  final Map<String, List<Map<String, dynamic>>> suggestionsByWarehouse;
  String? lastPostPath;
  Map<String, dynamic>? lastPostBody;
  int countRequests = 0;
  int rememberRequests = 0;
  final List<String> suggestionWarehouses = [];
  bool _saved = false;
  String? _savedWarehouseId;
  final Map<String, String> _savedPlaces = {};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/warehouses/dict') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓'},
        {'id': 'warehouse-2', 'name': '备用成品仓'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/tasks/count')) {
      countRequests++;
      return const {'count': 1};
    }
    if (path.endsWith('/place-suggestions')) {
      final selectedWarehouse = query?['warehouseId']?.toString() ?? '';
      suggestionWarehouses.add(selectedWarehouse);
      return {
        'items':
            suggestionsByWarehouse[selectedWarehouse] ??
            [
              for (final item in _itemsJson())
                {
                  'reportItemId': item['reportItemId'],
                  'place': placeHint,
                  'source': placeHint?.isNotEmpty == true
                      ? 'GOODS_MASTER'
                      : 'NONE',
                },
            ],
      };
    }
    if (path ==
        '/warehouse/production-finished-in/arrival-registrations/$_reportId') {
      return _detailJson();
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/remember-places')) {
      rememberRequests++;
      if (failFirstRemember && rememberRequests == 1) {
        throw NetworkException('默认库位服务暂时不可用');
      }
      return const {
        'remembered': 1,
        'unchanged': 0,
        'ambiguous': 0,
        'warnings': <String>[],
      };
    }
    lastPostPath = path;
    lastPostBody = Map<String, dynamic>.from(body! as Map);
    _saved = true;
    _savedWarehouseId = lastPostBody?['warehouseId'] as String?;
    for (final item in (lastPostBody?['items'] as List? ?? const [])) {
      final row = Map<String, dynamic>.from(item as Map);
      _savedPlaces[row['reportItemId'] as String] = row['place'] as String;
    }
    return _detailJson();
  }

  Map<String, dynamic> _detailJson() {
    final registeredValue = registered || _saved;
    final selectedWarehouse = _savedWarehouseId ?? warehouseId;
    return {
      'registrationId': registeredValue
          ? '40000000-0000-0000-0000-000000000001'
          : null,
      'registered': registeredValue,
      'reportId': _reportId,
      'reportNo': 'RB202608300001',
      'reportDate': '2026-08-30',
      'departmentId': '50000000-0000-0000-0000-000000000001',
      'workshopName': '注塑车间',
      'warehouseId': selectedWarehouse,
      'warehouseCode': selectedWarehouse == null ? null : 'CP',
      'warehouseName': selectedWarehouse == null ? null : '成品仓',
      'receiverEmployeeId': '60000000-0000-0000-0000-000000000001',
      'receiverName': '仓库管理员',
      'registeredAt': registeredValue ? '2026-08-30T08:30:00Z' : null,
      'items': _itemsJson(),
    };
  }

  List<Map<String, dynamic>> _itemsJson() => [
    _itemJson(reportItemId: '30000000-0000-0000-0000-000000000001', lineNo: 1),
    if (duplicateGoodsRows)
      _itemJson(
        reportItemId: '30000000-0000-0000-0000-000000000002',
        lineNo: 2,
      ),
  ];

  Map<String, dynamic> _itemJson({
    required String reportItemId,
    required int lineNo,
  }) => {
    'reportItemId': reportItemId,
    'lineNo': lineNo,
    'planItemId': '70000000-0000-0000-0000-000000000001',
    'executionSegmentId': '80000000-0000-0000-0000-000000000001',
    'planId': '90000000-0000-0000-0000-000000000001',
    'planNo': 'SJ202608300001',
    'goodsId': 'a0000000-0000-0000-0000-000000000001',
    'goodsCode': 'V51043',
    'goodsName': '三极插套',
    'colorId': null,
    'colorName': '—',
    'unitId': 'b0000000-0000-0000-0000-000000000001',
    'unitName': '只',
    'reportedQty': 10,
    'place': _savedPlaces[reportItemId] ?? place,
    'placeHint': placeHint,
  };
}

class _DeferredSuggestionApi extends _ArrivalRegistrationApi {
  _DeferredSuggestionApi({super.placeHint, super.duplicateGoodsRows});

  final Map<String, Completer<Map<String, dynamic>>> _pendingSuggestions = {};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/place-suggestions')) {
      final warehouseId = query?['warehouseId']?.toString() ?? '';
      suggestionWarehouses.add(warehouseId);
      final current = _pendingSuggestions[warehouseId];
      if (current != null && !current.isCompleted) return current.future;
      final next = Completer<Map<String, dynamic>>();
      _pendingSuggestions[warehouseId] = next;
      return next.future;
    }
    return super.get(path, query: query);
  }

  void completeSuggestion(
    String warehouseId, {
    required String? place,
    String source = 'WAREHOUSE_PREFERENCE',
  }) {
    completeSuggestionItems(warehouseId, [
      for (final item in _itemsJson())
        {
          'reportItemId': item['reportItemId'],
          'place': place,
          'source': source,
        },
    ]);
  }

  void completeSuggestionItems(
    String warehouseId,
    List<Map<String, dynamic>> items,
  ) {
    final pending = _pendingSuggestions[warehouseId];
    if (pending == null) {
      throw StateError('No pending suggestion request for $warehouseId');
    }
    pending.complete({'items': items});
  }

  void failSuggestion(String warehouseId) {
    final pending = _pendingSuggestions[warehouseId];
    if (pending == null) {
      throw StateError('No pending suggestion request for $warehouseId');
    }
    pending.completeError(NetworkException('成品仓默认库位加载失败'));
  }
}
