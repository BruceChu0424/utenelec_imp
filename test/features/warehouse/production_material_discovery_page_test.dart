import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/pages/production_material_discovery_page.dart';
import 'package:uten_imp/features/warehouse/repositories/production_material_discovery_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/production_material_discovery.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Map<String, dynamic> _detail({String status = 'PENDING'}) => {
  'requestId': 'request',
  'segmentId': 'segment',
  'segmentCode': 'ZX001',
  'planNo': 'SJ001',
  'productCode': 'SHELL',
  'productName': '外壳',
  'plannedQty': 1000,
  'productUnitName': '个',
  'workshopName': '注塑车间',
  'status': status,
  'version': 0,
  'items': <Map<String, dynamic>>[],
  'drawDocIds': <String>[],
};
const _material = {
  'goodsId': 'plastic',
  'goodsName': '塑料',
  'goodsCode': 'P01',
  'colorId': 'white',
  'colorName': '白色',
  'unitId': 'kg',
  'unitName': '千克',
  'warehouseId': 'leaf-warehouse',
  'warehouseName': '原料仓',
  'qty': '12.5',
};

class _Repository extends ProductionMaterialDiscoveryRepository {
  _Repository() : super(ApiClient(Dio()));
  final submissions =
      <({String key, int version, List<Map<String, dynamic>> items})>[];
  Object? failure;
  bool configured = false;
  String? requestNo;
  List<Map<String, dynamic>> drawDocuments = [];
  List<String> drawDocIds = [];
  List<Map<String, dynamic>> suggestions = [];
  @override
  Future<ProductionMaterialDiscoveryDetail> detail(String id) async =>
      ProductionMaterialDiscoveryDetail.fromJson({
        ..._detail(status: configured ? 'CONFIGURED' : 'PENDING'),
        'suggestedItems': suggestions,
        'requestNo': requestNo,
        'drawDocuments': drawDocuments,
        'drawDocIds': drawDocIds,
      });
  @override
  Future<ProductionMaterialDiscoveryDetail> configure({
    required String id,
    required int version,
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
  }) async {
    submissions.add((key: idempotencyKey, version: version, items: items));
    if (failure != null) throw failure!;
    configured = true;
    return ProductionMaterialDiscoveryDetail.fromJson({
      ..._detail(status: 'CONFIGURED'),
      'items': [
        {..._material, 'qty': items.first['qty']},
      ],
      'drawDocIds': ['draw-real'],
    });
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repo, {
  Size size = const Size(1400, 900),
  bool permitted = true,
  double scale = 1,
  GoRouter? router,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  Widget frame(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Stack(
      children: [
        child!,
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AppNotificationHost(useSafeArea: false),
        ),
      ],
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue({
          Perm.stockDocView,
          if (permitted) Perm.stockDocIssue,
          if (permitted) Perm.stockDocApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        productionMaterialDiscoveryRepositoryProvider.overrideWithValue(repo),
      ],
      child: router == null
          ? MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: frame,
              home: const ProductionMaterialDiscoveryPage(requestId: 'request'),
            )
          : MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: frame,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

DiscoveryMaterialRow _row(WidgetTester tester) => tester
    .widget<MasterDataTableView<DiscoveryMaterialRow>>(
      find.byType(MasterDataTableView<DiscoveryMaterialRow>),
    )
    .items
    .first;

Future<void> _revealHeader(WidgetTester tester) async {
  // Editing the table can collapse the independent outer header. Completion
  // must preserve the generated document link, not reset the user's scroll.
  final state = tester.state<NestedScrollViewState>(
    find.byType(NestedScrollView),
  );
  state.outerController.jumpTo(0);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'request detail shows its real LQ and opens each formal SL with its physical warehouse',
    (tester) async {
      final repo = _Repository()
        ..configured = true
        ..requestNo = 'LQ202609260001'
        ..drawDocIds = ['draw-a', 'draw-b']
        ..drawDocuments = [
          {
            'id': 'draw-a',
            'billNo': 'SL202609260011',
            'warehouseId': 'w-a',
            'warehouseName': '原料一仓',
          },
          {
            'id': 'draw-b',
            'billNo': 'SL202609260012',
            'warehouseId': 'w-b',
            'warehouseName': '原料二仓',
          },
        ];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const ProductionMaterialDiscoveryPage(requestId: 'request'),
          ),
          GoRoute(
            path: '/warehouse/DRAW/:id',
            builder: (_, state) =>
                Scaffold(body: Text('已打开 ${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, repo, router: router);
      expect(find.text('领料申请号：LQ202609260001'), findsOneWidget);
      expect(find.text('打开领料单 SL202609260011 · 原料一仓'), findsOneWidget);
      expect(find.text('打开领料单 SL202609260012 · 原料二仓'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('discovery-open-draw-draw-b')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已打开 draw-b'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('discovery-open-draw-draw-a')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已打开 draw-a'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old payload leaves the request number unknown and retains only real legacy document links',
    (tester) async {
      final repo = _Repository()
        ..configured = true
        ..drawDocIds = ['old-real-draw'];
      await _pump(tester, repo);
      expect(find.text('领料申请号：—'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('discovery-open-draw-old-real-draw')),
        findsOneWidget,
      );
      expect(find.text('打开领料单'), findsOneWidget);
      expect(find.textContaining('LQ'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'warehouse material metadata fills automatically while quantity and physical warehouse stay unconfirmed',
    (tester) async {
      await _pump(tester, _Repository());
      final row = _row(tester);
      row.selectGoods(
        const GoodsListItem(
          id: 'plastic',
          name: '塑料颗粒',
          code: 'P01',
          spec: 'PC-ABS',
          colorId: 'white',
          colorName: '白色',
          unitId: 'kg',
          unitName: '千克',
          stockPlace: 'A-01',
          owningWarehouseId: 'owner-only',
        ),
      );
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<DiscoveryMaterialRow>>(
        find.byKey(const Key('discovery-material-table')),
      );
      for (final field in {
        'goodsCode': 'P01',
        'spec': 'PC-ABS',
        'colorName': '白色',
        'stockPlace': 'A-01',
      }.entries) {
        final column = table.columns.firstWhere(
          (column) => column.key == field.key,
        );
        expect(column.value(row), field.value);
        expect(column.cellBuilder, isNull);
        expect(column.value(table.items.last), '—');
      }
      // 2026-10-10 数量内联口径：独立「单位」列撤销，单位进领料数量输入框后缀。
      expect(
        table.columns.any((column) => column.key == 'unitName'),
        isFalse,
      );
      expect(find.text('千克'), findsOneWidget);
      expect(row.values.containsKey('warehouseId'), isFalse);
      expect(row.qty.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'reselecting goods preserves color identity and resets quantity only on material or unit changes',
    () {
      final row = DiscoveryMaterialRow(
        initial: {..._material, 'colorId': 'blue', 'colorName': '蓝色'},
      );
      addTearDown(row.dispose);
      row.selectGoods(
        const GoodsListItem(
          id: 'plastic',
          colorId: 'white',
          colorName: '白色',
          unitId: 'kg',
        ),
      );
      expect(row.values['colorId'], 'blue');
      expect(row.values['colorName'], '蓝色');
      expect(row.qty.text, '12.5');
      row.selectGoods(
        const GoodsListItem(id: 'plastic', colorId: 'white', unitId: 'g'),
      );
      expect(row.values['colorId'], 'blue');
      expect(row.values['unitId'], 'g');
      expect(row.qty.text, isEmpty);
      row.qty.text = '25';
      row.selectGoods(
        const GoodsListItem(id: 'pigment', colorId: 'red', unitId: 'g'),
      );
      expect(row.values['colorId'], 'red');
      expect(row.qty.text, isEmpty);
    },
  );
  testWidgets('material-only suggestions leave quantity for the warehouse', (
    tester,
  ) async {
    final repo = _Repository()
      ..suggestions = [
        {..._material, 'qty': null, 'warehouseId': null, 'warehouseName': null},
      ];
    await _pump(tester, repo);
    expect(_row(tester).values['goodsId'], 'plastic');
    expect(_row(tester).qty.text, isEmpty);
    expect(_row(tester).toRequest(), isNull);
    await tester.tap(find.byKey(const Key('discovery-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions, isEmpty);
    expect(find.textContaining('第 1 行'), findsOneWidget);
    expect(find.textContaining('需要选择实际发料仓'), findsOneWidget);
    final table = tester.widget<MasterDataTableView<DiscoveryMaterialRow>>(
      find.byKey(const Key('discovery-material-table')),
    );
    for (final key in ['goods', 'qty', 'warehouse']) {
      expect(
        table.columns.firstWhere((column) => column.key == key).label,
        endsWith(' *'),
      );
    }
    _row(
      tester,
    ).values.addAll({'warehouseId': 'leaf-warehouse', 'warehouseName': '原料仓'});
    await tester.enterText(
      find.byKey(const ValueKey('discovery-qty-0')),
      '4.2500',
    );
    await tester.tap(find.byKey(const Key('discovery-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions.single.items.single['qty'], '4.2500');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'warehouse can add and remove material rows without losing remaining input',
    (tester) async {
      final repo = _Repository()..suggestions = [_material];
      await _pump(tester, repo);
      final original = _row(tester);
      await tester.tap(find.byKey(const Key('discovery-add')));
      await tester.pumpAndSettle();
      var table = tester.widget<MasterDataTableView<DiscoveryMaterialRow>>(
        find.byKey(const Key('discovery-material-table')),
      );
      expect(table.items, hasLength(2));
      final added = table.items.last;
      added.values.addAll({..._material, 'goodsId': 'pigment'});
      added.qty.text = '1.25';
      tester
          .widget<IconButton>(
            find.byKey(ValueKey('discovery-remove-${original.id}')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      table = tester.widget<MasterDataTableView<DiscoveryMaterialRow>>(
        find.byKey(const Key('discovery-material-table')),
      );
      expect(table.items.single.id, added.id);
      expect(table.items.single.qty.text, '1.25');
      await tester.tap(find.byKey(const Key('discovery-save')));
      await tester.pumpAndSettle();
      expect(repo.submissions.single.items.single['goodsId'], 'pigment');
      expect(repo.submissions.single.items.single['qty'], '1.25');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('workshop materials carry through to normal warehouse issue', (
    tester,
  ) async {
    final suggestion = Map<String, dynamic>.from(_material)
      ..remove('warehouseId')
      ..remove('warehouseName');
    final repo = _Repository()..suggestions = [suggestion];
    await _pump(tester, repo);
    expect(_row(tester).values['goodsId'], 'plastic');
    expect(_row(tester).values['colorId'], 'white');
    expect(_row(tester).values['unitId'], 'kg');
    expect(_row(tester).qty.text, '12.5');
    expect(find.textContaining('无需重复选料'), findsOneWidget);
    await tester.tap(find.byKey(const Key('discovery-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions, isEmpty);
    _row(
      tester,
    ).values.addAll({'warehouseId': 'leaf-warehouse', 'warehouseName': '原料仓'});
    await tester.tap(find.byKey(const Key('discovery-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions.single.items.single, {
      'goodsId': 'plastic',
      'colorId': 'white',
      'unitId': 'kg',
      'warehouseId': 'leaf-warehouse',
      'qty': '12.5',
    });
    await _revealHeader(tester);
    expect(find.text('打开领料单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('checking pending result preserves edited workshop suggestions', (
    tester,
  ) async {
    final repo = _Repository()
      ..suggestions = [_material]
      ..failure = ApiException('CONFLICT', '库存已变化', httpStatus: 409);
    await _pump(tester, repo);
    await tester.enterText(
      find.byKey(const ValueKey('discovery-qty-0')),
      '9.75',
    );
    await tester.tap(find.byKey(const Key('discovery-save')));
    await tester.pumpAndSettle();
    // 行高统一后表格更矮，提交期间外层折叠头会被滚出缓存区——先拉回再点
    // 头部的「核对提交结果」（与本文件其它用例的 _revealHeader 同一处理）。
    await _revealHeader(tester);
    await tester.tap(find.text('核对提交结果'));
    await tester.pumpAndSettle();
    expect(_row(tester).qty.text, '9.75');
    expect(_row(tester).values['warehouseId'], 'leaf-warehouse');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'confirmed facts replace suggestions after concurrent completion',
    (tester) async {
      final repo = _Repository()
        ..configured = true
        ..suggestions = [_material];
      await _pump(tester, repo);
      final grid = tester.widget<MasterDataTableView<DiscoveryMaterialRow>>(
        find.byType(MasterDataTableView<DiscoveryMaterialRow>),
      );
      expect(grid.items, isEmpty);
      expect(find.textContaining('无需重复选料'), findsNothing);
      expect(find.byKey(const Key('discovery-save')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a concurrent warehouse configuration can be reviewed after conflict',
    (tester) async {
      final repo = _Repository()
        ..failure = ApiException('CONFLICT', '仓库已登记此申请', httpStatus: 409);
      await _pump(tester, repo);
      _row(tester).values.addAll(_material);
      _row(tester).qty.text = '12.5';
      await tester.tap(find.byKey(const Key('discovery-save')));
      await tester.pumpAndSettle();
      expect(_row(tester).qty.text, '12.5');
      expect(find.text('核对提交结果'), findsOneWidget);
      repo.configured = true;
      await tester.tap(find.text('核对提交结果'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discovery-save')), findsNothing);
      await _revealHeader(tester);
      expect(find.text('该申请已办理，请查看对应领料单'), findsOneWidget);
      expect(repo.submissions, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'warehouse material color is displayed automatically without an input',
    (tester) async {
      final repo = _Repository()
        ..suggestions = [
          {..._material, 'colorId': 'blue', 'colorName': '蓝色'},
        ];
      await _pump(tester, repo);
      _row(tester).qty.text = '2.5';
      final table = tester.widget<MasterDataTableView<DiscoveryMaterialRow>>(
        find.byKey(const Key('discovery-material-table')),
      );
      final colorColumn = table.columns.firstWhere(
        (column) => column.key == 'colorName',
      );
      expect(colorColumn.value(table.items.single), '蓝色');
      expect(colorColumn.cellBuilder, isNull);
      table.items.single.values['colorName'] = null;
      expect(colorColumn.value(table.items.single), '—');
      table.items.single.values['colorName'] = '';
      expect(colorColumn.value(table.items.single), '—');
      table.items.single.values['colorName'] = '  ';
      expect(colorColumn.value(table.items.single), '—');
      expect(table.columns.first.key, 'goods');
      expect(table.columns.first.value(table.items.single), '塑料');
      expect(
        table.columns
            .firstWhere((column) => column.key == 'usedFor')
            .value(table.items.single),
        contains('外壳'),
      );
      expect(
        table.columns
            .firstWhere((column) => column.key == 'usedFor')
            .value(table.items.single),
        contains('ZX001'),
      );
      await tester.tap(find.byKey(const Key('discovery-save')));
      await tester.pumpAndSettle();
      expect(repo.submissions.single.items.single['colorId'], 'blue');
      expect(repo.submissions.single.items.single['unitId'], 'kg');
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'quantity preserves material, color, base unit and exact warehouse identity',
    () {
      final row = DiscoveryMaterialRow(initial: _material);
      addTearDown(row.dispose);
      expect(row.toRequest(), {
        'goodsId': 'plastic',
        'colorId': 'white',
        'unitId': 'kg',
        'warehouseId': 'leaf-warehouse',
        'qty': '12.5',
      });
      for (final invalid in ['0', '-1', 'NaN', '1.00001', '']) {
        row.qty.text = invalid;
        expect(row.toRequest(), isNull, reason: invalid);
      }
    },
  );
  testWidgets('empty rows cannot create material facts', (tester) async {
    final repo = _Repository();
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('discovery-save')));
    await tester.pumpAndSettle();
    expect(repo.submissions, isEmpty);
    expect(find.textContaining('请逐行选择材料'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'warehouse saves quantity with unit and opens standard issue afterward',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      _row(tester).values.addAll(_material);
      _row(tester).qty.text = '12.7500';
      await tester.tap(find.byKey(const Key('discovery-save')));
      await tester.pumpAndSettle();
      expect(repo.submissions.single.items.single['qty'], '12.7500');
      expect(
        repo.submissions.single.items.single['warehouseId'],
        'leaf-warehouse',
      );
      await _revealHeader(tester);
      expect(find.text('打开领料单'), findsOneWidget);
      expect(find.byKey(const Key('discovery-save')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'uncertain response preserves input and reuses exact idempotent request',
    (tester) async {
      final repo = _Repository()..failure = NetworkTimeoutException();
      await _pump(tester, repo);
      _row(tester).values.addAll(_material);
      _row(tester).qty.text = '12.5';
      await tester.tap(find.byKey(const Key('discovery-save')));
      await tester.pumpAndSettle();
      expect(_row(tester).qty.text, '12.5');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('discovery-qty-0')))
            .readOnly,
        isTrue,
      );
      repo.failure = null;
      await tester.tap(find.byKey(const Key('discovery-save')));
      await tester.pumpAndSettle();
      expect(repo.submissions, hasLength(2));
      expect(repo.submissions[0].key, repo.submissions[1].key);
      expect(repo.submissions[0].items, repo.submissions[1].items);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('viewer sees request but cannot define or submit materials', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo, permitted: false);
    expect(find.byKey(const Key('discovery-save')), findsNothing);
    expect(find.text('当前账号没有填写领料物料的权限'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(390, 844), const Size(760, 900)]) {
    testWidgets('material table remains usable at $size with large text', (
      tester,
    ) async {
      await _pump(tester, _Repository(), size: size, scale: 1.4);
      expect(
        find.byType(MasterDataTableView<DiscoveryMaterialRow>),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
