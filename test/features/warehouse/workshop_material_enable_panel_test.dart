// 车间内料仓开通面板 (ADR-147): 右侧滑窗, 多车间, 发料来源仓走全站仓库滑窗 (先主仓再子仓,
// 只能选启用中的良品子仓), 在产认料按产品去重, 全成全败失败后保留输入并复用同一个请求号。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_enable_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _main = {
  'id': 'main',
  'code': '001',
  'name': '仓库(14年版)',
  'parentId': null,
  'status': '使用',
  'defective': false,
  'selectable': false,
};
const _plastic = {
  'id': 'plastic',
  'code': 'XW01',
  'name': '塑胶仓库',
  'parentId': 'main',
  'status': '使用',
  'defective': false,
  'selectable': true,
};
const _defective = {
  'id': 'bad',
  'code': 'C0401',
  'name': '成品不良品仓',
  'parentId': 'main',
  'status': '使用',
  'defective': true,
  'selectable': false,
  'selectableDefective': true,
};

Map<String, dynamic> _pending(String product, String name) => {
  'productGoodsId': product,
  'productName': name,
  'taskCount': 1,
  'options': [
    {'goodsId': 'pc', 'goodsCode': 'PC-01', 'goodsName': 'PC 颗粒'},
  ],
  'prefill': <Object>[],
  'bomWeights': <Object>[],
  'alsoOrderMaterialsAllowed': false,
};

class _SetupOnlyApi extends ApiClient {
  _SetupOnlyApi() : super(Dio());
  final reads = <String>[];
  final pendingQueries = <Map<String, dynamic>?>[];
  final posts = <Map<String, dynamic>>[];
  Object? failOnce;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path == '/workshop-material/settings/source-warehouses') {
      return [_main, _plastic, _defective];
    }
    throw ApiException('FORBIDDEN', '没有通用仓库或库存读取权限');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path == '/workshop-material/settings/in-progress-pending') {
      pendingQueries.add(query);
      // 服务端按产品去重: 同一个产品在两个车间都在产, 只来一行并带两个车间名。
      return {
        'products': [
          {
            ..._pending('cup', '水杯'),
            'taskCount': 3,
            'workshopNames': ['注塑车间', '装配车间'],
          },
        ],
      };
    }
    throw ApiException('FORBIDDEN', '没有额外读取权限');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/workshop-material/settings/batch-enable');
    final saved = Map<String, dynamic>.from(body! as Map);
    posts.add(saved);
    final failure = failOnce;
    if (failure != null) {
      failOnce = null;
      throw failure;
    }
    return {
      'settings': [
        for (final item in saved['items'] as List)
          {
            'workshopDepartmentId': (item as Map)['workshopId'],
            'workshopName': '车间',
            'status': saved['periodic'] == true ? 'OPEN_PERIODIC' : 'OPEN',
            'binWarehouseId': 'bin-${item['workshopId']}',
            'rowVersion': 1,
          },
      ],
    };
  }
}

const _shopA = WmSetting(
  workshopDepartmentId: 'shop-a',
  workshopName: '注塑车间',
  status: WmBinStatus.notOpen,
  allowedActions: ['SETUP', 'OPEN', 'ENABLE_PERIODIC'],
);
const _shopB = WmSetting(
  workshopDepartmentId: 'shop-b',
  workshopName: '装配车间',
  status: WmBinStatus.open,
  binWarehouseId: 'bin-b',
  rowVersion: 4,
  allowedActions: ['SETUP', 'ENABLE_PERIODIC', 'CHANGE_SOURCE'],
);

Future<List<List<WmSetting>>> _mount(
  WidgetTester tester,
  _SetupOnlyApi api, {
  required List<WmSetting> settings,
  required WmBinPanelMode mode,
}) async {
  final results = <List<WmSetting>>[];
  tester.view
    ..physicalSize = const Size(1400, 950)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.workshopMaterialSetup,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        workshopMaterialRepositoryProvider.overrideWithValue(
          WorkshopMaterialRepository(api),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showWorkshopBinOpeningPanel(
                  context,
                  settings: settings,
                  mode: mode,
                );
                if (result != null) results.add(result);
              },
              child: const Text('打开面板'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开面板'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets(
    'setup-only opens without the warehouse dictionary; source picker '
    'drills main -> sub-warehouse and only good leaves are selectable',
    (tester) async {
      final api = _SetupOnlyApi();
      final results = await _mount(
        tester,
        api,
        settings: const [_shopA],
        mode: WmBinPanelMode.open,
      );
      expect(api.reads, ['/workshop-material/settings/source-warehouses']);
      expect(find.textContaining('没有通用仓库'), findsNothing);
      expect(find.text('按货品所属仓库'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wm-bin-panel-source')));
      await tester.pumpAndSettle();
      expect(find.text('选择内料仓的发料来源仓'), findsOneWidget);
      // 先主仓 (只导航), 再子仓。
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-main')));
      await tester.pumpAndSettle();
      final defective = tester.widget<ListTile>(
        find.byKey(const Key('warehouse-picker-entry-bad')),
      );
      expect(defective.enabled, isFalse, reason: '不良品仓不能当发料来源仓');
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-plastic')));
      await tester.pumpAndSettle();
      expect(find.text('仓库(14年版)-塑胶仓库'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
      await tester.pumpAndSettle();
      final body = api.posts.single;
      expect(body['sourceWarehouseId'], 'plastic');
      expect(body['periodic'], false);
      expect(body['items'], [
        {
          'workshopId': 'shop-a',
          'expectedStatus': 'NOT_OPEN',
          'expectedVersion': 0,
        },
      ]);
      expect(results.single.single.status, WmBinStatus.open);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch periodic for two workshops: in-progress choices are one row '
    'per product, missing choice blocks, failure keeps input and reuses the key',
    (tester) async {
      final api = _SetupOnlyApi();
      final results = await _mount(
        tester,
        api,
        settings: const [_shopA, _shopB],
        mode: WmBinPanelMode.periodic,
      );
      expect(api.pendingQueries.single, {'workshopIds': 'shop-a,shop-b'});
      expect(find.textContaining('所选车间 (2)'), findsOneWidget);
      expect(find.text('水杯'), findsOneWidget);
      expect(find.text('注塑车间、装配车间'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(find.textContaining('还有 1 个在产产品没选料'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wm-enable-choice-cup')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('PC 颗粒').last);
      await tester.pumpAndSettle();

      api.failOnce = ApiException(
        'CONFLICT',
        '「装配车间」的内料仓设置已被别人改过, 请刷新后再试',
        httpStatus: 409,
      );
      await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
      await tester.pumpAndSettle();
      expect(find.text('「装配车间」的内料仓设置已被别人改过, 请刷新后再试'), findsOneWidget);
      expect(results, isEmpty);

      await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
      await tester.pumpAndSettle();
      expect(api.posts, hasLength(2));
      expect(api.posts[0]['idempotencyKey'], api.posts[1]['idempotencyKey']);
      final body = api.posts[1];
      expect(body['periodic'], true);
      expect(body['goLiveDate'], isNotNull);
      expect(body['items'], [
        {
          'workshopId': 'shop-a',
          'expectedStatus': 'NOT_OPEN',
          'expectedVersion': 0,
        },
        {
          'workshopId': 'shop-b',
          'expectedStatus': 'OPEN',
          'expectedVersion': 4,
        },
      ]);
      expect(body['inProgressChoices'], [
        {
          'productGoodsId': 'cup',
          'kind': 'MATERIAL',
          'materials': [
            {'goodsId': 'pc', 'colorId': null},
          ],
          'alsoOrderMaterials': false,
        },
      ]);
      expect(results.single, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('open mode reads in-progress choices only after turning on '
      'batch issuing', (tester) async {
    final api = _SetupOnlyApi();
    await _mount(
      tester,
      api,
      settings: const [_shopA],
      mode: WmBinPanelMode.open,
    );
    expect(api.pendingQueries, isEmpty);
    expect(find.text('水杯'), findsNothing);
    await tester.tap(find.byKey(const Key('wm-bin-panel-periodic')));
    await tester.pumpAndSettle();
    expect(api.pendingQueries.single, {'workshopIds': 'shop-a'});
    expect(find.text('水杯'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('change-source mode requires a source and never sends periodic', (
    tester,
  ) async {
    final api = _SetupOnlyApi();
    await _mount(
      tester,
      api,
      settings: const [_shopB],
      mode: WmBinPanelMode.source,
    );
    expect(api.pendingQueries, isEmpty);
    expect(find.byKey(const Key('wm-bin-panel-periodic')), findsNothing);
    await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
    await tester.pumpAndSettle();
    expect(api.posts, isEmpty);
    expect(find.text('请选择发料来源仓'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'change-source mode can return to following the owning warehouse',
    (tester) async {
      final api = _SetupOnlyApi();
      await _mount(
        tester,
        api,
        settings: const [_shopB],
        mode: WmBinPanelMode.source,
      );
      // 设过来源仓以后也能回到「按货品所属仓库」(来源仓置空), 不再被迫另选一个仓。
      await tester.tap(find.byKey(const Key('wm-bin-panel-follow-owning')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wm-bin-panel-submit')));
      await tester.pumpAndSettle();
      expect(api.posts, hasLength(1));
      expect(api.posts.single['clearSource'], isTrue);
      expect(api.posts.single['sourceWarehouseId'], isNull);
      expect(api.posts.single['periodic'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
