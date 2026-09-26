import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
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
  @override
  Future<ProductionMaterialDiscoveryDetail> detail(String id) async =>
      ProductionMaterialDiscoveryDetail.fromJson(
        _detail(status: configured ? 'CONFIGURED' : 'PENDING'),
      );
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
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue({
          Perm.stockDocView,
          if (permitted) Perm.stockDocIssue,
          if (permitted) Perm.stockDocApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        productionMaterialDiscoveryRepositoryProvider.overrideWithValue(repo),
        colorDictProvider.overrideWith(
          (ref) async => const [
            ColorListItem(id: 'white', name: '白色'),
            ColorListItem(id: 'blue', name: '蓝色'),
          ],
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
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
        ),
        home: const ProductionMaterialDiscoveryPage(requestId: 'request'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

DiscoveryMaterialRow _row(WidgetTester tester) => tester
    .widget<UtenEditableGrid<DiscoveryMaterialRow>>(
      find.byType(UtenEditableGrid<DiscoveryMaterialRow>),
    )
    .controller
    .rows
    .first;

void main() {
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
      expect(find.text('该申请已办理，请查看对应领料单'), findsOneWidget);
      expect(repo.submissions, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'warehouse can choose the actual color instead of the goods default',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      _row(tester).values.addAll(_material);
      _row(tester).qty.text = '2.5';
      await tester.tap(find.byKey(const ValueKey('discovery-color-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('蓝色').last);
      await tester.pumpAndSettle();
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
        find.byType(UtenEditableGrid<DiscoveryMaterialRow>),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
