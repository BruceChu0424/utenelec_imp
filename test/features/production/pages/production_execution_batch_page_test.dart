import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_draw_request.dart';
import 'package:uten_imp/features/production/models/production_execution_batch.dart';
import 'package:uten_imp/features/production/pages/production_execution_batch_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_batch_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../support/audit_screenshot_support.dart';

const _quantityKey = Key('execution-batch-quantity');
const _previewKey = Key('execution-batch-preview');
const _submitKey = Key('execution-batch-submit');
const _tableKey = Key('execution-batch-material-table');
const _captureScreenshots = bool.fromEnvironment('UTEN_CAPTURE_BATCH_DRAW');

Map<String, dynamic> _snapshot({
  double quantity = 300,
  double max = 300,
  int version = 5,
}) => {
  'segmentId': 'segment-a',
  'expectedVersion': version,
  'originalQty': 1000,
  'maxReadyQty': max,
  'quantity': quantity,
  'remainingQty': 1000 - quantity,
  'fingerprint': 'snapshot-$quantity-$version',
  'planId': 'plan-a',
  'planNo': 'SC-1',
  'segmentCode': 'GD-1',
  'productCode': 'V5-001',
  'productName': '测试产品',
  'productUnitName': '件',
  'summaries': [
    if (quantity > 0)
      {
        'warehouseId': 'warehouse-a',
        'warehouseName': '原料仓',
        'goodsId': 'goods-a',
        'goodsCode': 'M-01',
        'goodsName': '塑料颗粒',
        'unitId': 'unit-a',
        'unitName': '千克',
        'qty': quantity * 0.5,
      },
  ],
};

class _Repository extends ProductionExecutionBatchRepository {
  _Repository() : super(ApiClient(Dio()));
  final previews = <({String id, int? version, double? quantity})>[];
  final submissions =
      <({ProductionExecutionBatchPreview preview, String key})>[];
  double maximum = 300;
  bool reuseMaterial = false;
  bool showIllustrativeMaterials = false;
  Object? submitError;

  @override
  Future<ProductionExecutionBatchPreview> preview({
    required String segmentId,
    int? expectedVersion,
    double? quantity,
  }) async {
    previews.add((id: segmentId, version: expectedVersion, quantity: quantity));
    return ProductionExecutionBatchPreview.fromJson({
      ..._snapshot(quantity: quantity ?? maximum, max: maximum),
      if (showIllustrativeMaterials) ...{
        'planNo': 'SC202609120018',
        'segmentCode': 'GD202609120032',
        'productName': '外贸 V5 多功能插座功能件',
        'summaries': [
          for (final material in [
            (
              id: 'a',
              code: 'M-001',
              name: '阻燃塑料颗粒',
              warehouse: '塑料原料仓',
              unit: '千克',
              color: '白色',
              rate: 0.5,
            ),
            (
              id: 'b',
              code: 'M-012',
              name: '功能件铜片',
              warehouse: '五金配件仓',
              unit: '片',
              color: '本色',
              rate: 2.0,
            ),
            (
              id: 'c',
              code: 'M-035',
              name: '接地连接片',
              warehouse: '五金配件仓',
              unit: '片',
              color: '本色',
              rate: 1.0,
            ),
            (
              id: 'd',
              code: 'M-048',
              name: '紧固螺丝',
              warehouse: '五金配件仓',
              unit: '颗',
              color: '本色',
              rate: 4.0,
            ),
          ])
            {
              'warehouseId': material.warehouse == '塑料原料仓'
                  ? 'plastic'
                  : 'hardware',
              'warehouseName': material.warehouse,
              'goodsId': material.id,
              'goodsCode': material.code,
              'goodsName': material.name,
              'colorId': material.color,
              'colorName': material.color,
              'unitId': material.unit,
              'unitName': material.unit,
              'qty': (quantity ?? maximum) * material.rate,
            },
        ],
      },
      if (reuseMaterial) 'summaries': <Object>[],
    });
  }

  @override
  Future<ProductionExecutionBatchResult> submit({
    required ProductionExecutionBatchPreview preview,
    required String idempotencyKey,
  }) async {
    submissions.add((preview: preview, key: idempotencyKey));
    if (submitError != null) throw submitError!;
    return ProductionExecutionBatchResult(
      batchSegmentId: 'batch-a',
      remainingSegmentId: 'remaining-a',
      documentIds: reuseMaterial ? const [] : const ['draw-a'],
      replayed: false,
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool allowed = true,
  Size size = const Size(1400, 900),
  bool dark = false,
  double textScale = 1,
  GlobalKey? captureKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/batch',
    routes: [
      GoRoute(
        path: '/batch',
        builder: (_, _) => const ProductionExecutionBatchPage(
          segmentId: 'segment-a',
          expectedVersion: 4,
        ),
      ),
      GoRoute(
        path: '/production/workshop-tasks',
        builder: (_, _) => const Scaffold(body: Text('返回车间任务')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue(
          allowed
              ? {Perm.productionExecutionView, Perm.productionExecutionStart}
              : {Perm.productionExecutionView},
        ),
        productionExecutionBatchRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
      child: MaterialApp.router(
        theme: auditScreenshotTheme(
          dark ? buildDarkTheme() : buildLightTheme(),
        ),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => RepaintBoundary(
          key: captureKey,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectQuantityCard(WidgetTester tester, String name, String value) {
  expect(
    tester.widget<Text>(find.byKey(Key('execution-batch-$name-value'))).data,
    value,
  );
}

Future<void> _saveScreenshot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('.tmp/production-execution-batch-ui')
        ..createSync(recursive: true);
      File(
        '${directory.path}/$name.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets(
    'a batch using previously issued material does not send staff to collect again',
    (tester) async {
      final repository = _Repository()..reuseMaterial = true;
      await _pump(tester, repository);
      expect(find.text('确认本批生产'), findsOneWidget);
      expect(find.textContaining('无需再次领料'), findsWidgets);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(repository.submissions, hasLength(1));
      expect(find.text('返回车间任务'), findsOneWidget);
    },
  );
  testWidgets(
    'partial receipt previews a complete 300 batch and retains 700 without writing',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      expect(repository.previews.single, (
        id: 'segment-a',
        version: 4,
        quantity: null,
      ));
      _expectQuantityCard(tester, 'original', '1000');
      _expectQuantityCard(tester, 'ready', '300');
      _expectQuantityCard(tester, 'selected', '300');
      _expectQuantityCard(tester, 'remaining', '700');
      expect(find.textContaining('SC-1'), findsOneWidget);
      expect(find.textContaining('V5-001'), findsOneWidget);
      expect(find.text('150'), findsOneWidget);
      expect(find.text('千克'), findsOneWidget);
      expect(repository.submissions, isEmpty);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(repository.submissions.single.preview.quantity, 300);
      expect(repository.submissions.single.preview.expectedVersion, 5);
      expect(find.text('返回车间任务'), findsOneWidget);
    },
  );

  testWidgets(
    'changed batch quantity must be reviewed again before submission',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.enterText(find.byKey(_quantityKey), '200');
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(_previewKey));
      await tester.pumpAndSettle();
      expect(repository.previews.last.quantity, 200);
      _expectQuantityCard(tester, 'ready', '300');
      _expectQuantityCard(tester, 'selected', '200');
      _expectQuantityCard(tester, 'remaining', '800');
      expect(find.textContaining('留待后续安排'), findsWidgets);
      expect(find.textContaining('继续等待物料'), findsNothing);
      expect(find.textContaining('缺口'), findsNothing);
      expect(find.text('100'), findsOneWidget);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(repository.submissions.single.preview.quantity, 200);
    },
  );

  testWidgets(
    'no complete kit cannot create an empty or partial-reserved production batch',
    (tester) async {
      final repository = _Repository()..maximum = 0;
      await _pump(tester, repository);
      expect(
        find.descendant(
          of: find.byKey(_tableKey),
          matching: find.textContaining('尚不能配齐一个生产批次'),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed,
        isNull,
      );
      expect(repository.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'uncertain submission freezes quantity and reuses the same intent',
    (tester) async {
      final repository = _Repository()..submitError = NetworkTimeoutException();
      await _pump(tester, repository);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(find.text('重试本批领料'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(_quantityKey)).enabled,
        isFalse,
      );
      expect(
        tester.widget<UtenButton>(find.byKey(_previewKey)).onPressed,
        isNull,
      );
      repository.submitError = null;
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(repository.submissions.length, 2);
      expect(repository.submissions.first.key, repository.submissions.last.key);
      expect(
        identical(
          repository.submissions.first.preview,
          repository.submissions.last.preview,
        ),
        isTrue,
      );
    },
  );

  testWidgets('forbidden accounts cannot preview or write', (tester) async {
    final repository = _Repository();
    await _pump(tester, repository, allowed: false);
    expect(repository.previews, isEmpty);
    expect(repository.submissions, isEmpty);
  });

  for (final invalid in ['0', '-1', 'NaN', '0.00001', '301']) {
    testWidgets(
      'invalid quantity $invalid cannot request a preview or submit',
      (tester) async {
        final repository = _Repository();
        await _pump(tester, repository);
        await tester.enterText(find.byKey(_quantityKey), invalid);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_previewKey));
        await tester.pumpAndSettle();
        expect(repository.previews, hasLength(1));
        expect(repository.submissions, isEmpty);
        expect(
          tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed,
          isNull,
        );
        _expectQuantityCard(tester, 'selected', '300');
        _expectQuantityCard(tester, 'remaining', '700');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'material table participates in header scroll and action is red',
    (tester) async {
      await _pump(tester, _Repository());
      expect(
        tester
            .widget<MasterDataTableView<ProductionDrawRequestSummary>>(
              find.byKey(_tableKey),
            )
            .primary,
        isTrue,
      );
      expect(
        tester.widget<UtenButton>(find.byKey(_submitKey)).type,
        UtenButtonType.danger,
      );
      final materialQuantity = find.text('150');
      expect(
        tester.widget<Text>(materialQuantity).style?.color,
        Theme.of(tester.element(materialQuantity)).colorScheme.error,
      );
      expect(
        tester.widget<Text>(materialQuantity).style?.fontWeight,
        FontWeight.w700,
      );
    },
  );

  testWidgets('narrow batch review remains usable', (tester) async {
    await loadAuditScreenshotFonts(tester);
    final repository = _Repository();
    await _pump(tester, repository, size: const Size(390, 844));
    expect(find.text('确认本批领料'), findsOneWidget);
    await tester.drag(
      find.byType(UtenCollapsingHeaderScrollView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    final table = tester
        .widget<MasterDataTableView<ProductionDrawRequestSummary>>(
          find.byKey(_tableKey),
        );
    expect(table.columns.take(2).map((column) => column.key), ['name', 'qty']);
    final quantityRect = tester.getRect(find.text('150'));
    expect(quantityRect.left, greaterThanOrEqualTo(0));
    expect(quantityRect.right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final viewport in [
      (name: 'phone', size: const Size(390, 844)),
      (name: 'landscape', size: const Size(844, 390)),
      (name: 'desktop', size: const Size(1400, 900)),
    ]) {
      testWidgets(
        '${dark ? 'dark' : 'light'} ${viewport.name} keeps enlarged content and actions reachable',
        (tester) async {
          await loadAuditScreenshotFonts(tester);
          await _pump(
            tester,
            _Repository(),
            size: viewport.size,
            dark: dark,
            textScale: 1.5,
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(_submitKey).hitTestable(), findsOneWidget);
          if (viewport.name == 'phone') {
            final bottomBar = tester
                .widget<Scaffold>(find.byType(Scaffold))
                .bottomNavigationBar;
            expect(bottomBar, isNotNull);
            expect(
              tester
                  .getRect(find.byType(UtenCollapsingHeaderScrollView))
                  .bottom,
              lessThanOrEqualTo(tester.getRect(find.byWidget(bottomBar!)).top),
              reason: 'The compact action area must reserve body space.',
            );
          }
          await tester.ensureVisible(find.byKey(_quantityKey));
          await tester.pumpAndSettle();
          expect(find.byKey(_quantityKey).hitTestable(), findsOneWidget);
          await tester.ensureVisible(find.byKey(_tableKey));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(_submitKey).hitTestable(), findsOneWidget);
        },
      );
    }
  }

  for (final visual in [
    (name: 'desktop-light', size: const Size(1400, 900), dark: false),
    (name: 'desktop-dark', size: const Size(1400, 900), dark: true),
    (name: 'phone-light', size: const Size(390, 844), dark: false),
  ]) {
    testWidgets('capture batch draw ${visual.name}', (tester) async {
      await loadAuditScreenshotFonts(tester);
      final captureKey = GlobalKey();
      await _pump(
        tester,
        _Repository()..showIllustrativeMaterials = true,
        size: visual.size,
        dark: visual.dark,
        captureKey: captureKey,
      );
      expect(tester.takeException(), isNull);
      await _saveScreenshot(tester, captureKey, visual.name);
      if (visual.name == 'phone-light') {
        await tester.ensureVisible(find.byKey(_tableKey));
        await tester.pumpAndSettle();
        await _saveScreenshot(tester, captureKey, 'phone-light-materials');
      }
    }, skip: !_captureScreenshots);
  }

  test(
    'batch API submits authoritative reviewed quantities and fingerprints only',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: request.path.endsWith('/preview')
                    ? _snapshot()
                    : {
                        'batchSegmentId': 'b',
                        'remainingSegmentId': 'r',
                        'documentIds': ['d'],
                        'replayed': true,
                      },
              ),
            );
          },
        ),
      );
      final repository = ProductionExecutionBatchRepository(ApiClient(dio));
      final preview = await repository.preview(segmentId: 'segment-a');
      final result = await repository.submit(
        preview: preview,
        idempotencyKey: 'request-1',
      );
      expect(requests.first.data, {'segmentId': 'segment-a'});
      expect(requests.last.data, {
        'segmentId': 'segment-a',
        'expectedVersion': 5,
        'quantity': 300.0,
        'previewFingerprint': 'snapshot-300.0-5',
        'idempotencyKey': 'request-1',
      });
      expect(result.replayed, isTrue);
    },
  );
}
