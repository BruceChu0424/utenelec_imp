import 'package:dio/dio.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/pricing/procurement_price_check.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../../support/audit_screenshot_support.dart';
import 'package:uten_imp/features/basic_data/pages/goods_price_analysis_page.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_price_history_chart.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/pricing/price_analysis_models.dart';
import 'package:uten_imp/shared/pricing/price_summary_value.dart';
import 'package:uten_imp/shared/pricing/price_analysis_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _grants = StateProvider<Set<String>>(
  (_) => {
    Perm.goodsView,
    Perm.goodsPriceAnalysisView,
    Perm.materialCategoryView,
  },
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'reader', code: 'reader', name: '财务读者'),
  );
  void clear() =>
      state = const SessionState(status: AuthStatus.mustChangePassword);
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async =>
      ref.watch(authenticatedScopeProvider) == null ? null : SessionSnapshot();
}

class _Repository implements PriceAnalysisRepository {
  final queries = <Map<String, dynamic>>[];
  final historyQueries = <Map<String, dynamic>>[];
  final pending = <Completer<GoodsPriceAnalysis>>[];
  final pendingHistory = <Completer<PriceHistoryPage>>[];
  bool delayHistory = false;
  final checkRequests = <List<Map<String, dynamic>>>[];
  Map<String, dynamic> overrides = {};
  List<Map<String, dynamic>>? historyRows;
  bool delay = false;
  String status = 'READY';
  bool fail = false;
  @override
  Future<GoodsPriceAnalysis> analysis(
    String goodsId,
    Map<String, dynamic> query,
  ) {
    queries.add({'goodsId': goodsId, ...query});
    if (fail) return Future.error(StateError('offline'));
    if (delay) {
      final c = Completer<GoodsPriceAnalysis>();
      pending.add(c);
      return c.future;
    }
    return Future.value(
      GoodsPriceAnalysis({
        ...sample(goodsId: goodsId).data,
        'status': status,
        ...overrides,
      }),
    );
  }

  @override
  Future<PriceHistoryPage> history(
    String goodsId,
    Map<String, dynamic> query,
  ) async {
    historyQueries.add(query);
    if (delayHistory) {
      final c = Completer<PriceHistoryPage>();
      pendingHistory.add(c);
      return c.future;
    }
    return PriceHistoryPage({
      'observations':
          historyRows ??
          [
            observation(
              query.containsKey('cursor') ? 'archived-2' : 'archived-1',
            ),
          ],
      'hasMore': !query.containsKey('cursor'),
      'nextCursor': !query.containsKey('cursor') ? 'cursor' : null,
    });
  }

  @override
  Future<List<PriceCheckResult>> check(
    String kind,
    List<Map<String, dynamic>> items, {
    String? excludeOrderId,
    CancelToken? cancelToken,
  }) async {
    checkRequests.add(items);
    return [
      for (final item in items)
        PriceCheckResult({
          ...item,
          'status': 'READY',
          'severity': 'WARNING',
          'message': '服务端核对依据',
          'weightedAveragePrice': '10.25',
        }),
    ];
  }
}

Map<String, dynamic> observation(
  String id, {
  int day = 10,
  String price = '12.345678912345',
}) => {
  'sourceId': id,
  'sourceItemId': 'item-$id',
  'sourceType': 'PURCHASE_ORDER',
  'sourceNo': 'PO-$id',
  'businessDate': '2026-10-${day.toString().padLeft(2, '0')}',
  'partnerName': '测试供应商',
  'supplierId': 'supplier',
  'quantity': '100',
  'unitPrice': price,
  'amount': '1234.5678912345',
  'currencyId': 'cny',
  'currencyName': '人民币',
  'unitId': 'piece',
  'unitName': '个',
  'taxRate': '13',
  'comparable': true,
  'canOpenSource': false,
};
GoodsPriceAnalysis sample({String goodsId = 'a', String name = '测试货品'}) =>
    GoodsPriceAnalysis({
      'goodsId': goodsId,
      'goodsCode': 'M-001',
      'goodsName': name,
      'status': 'READY',
      'context': {
        'currencyName': '人民币',
        'unitName': '个',
        'taxMode': 'AS_RECORDED',
        'priceBasis': 'APPROVED_ORDER_TERMS',
      },
      'referencePrice': '12.345678912345',
      'weightedAveragePrice': '12.4',
      'lowerReferencePrice': '11.5',
      'upperReferencePrice': '13.5',
      'lastPrice': '12.6',
      'sampleCount': 3,
      'independentOrderCount': 3,
      'dataAsOf': '2026-10-13T08:00:00Z',
      'explanation': '基于相同单位、币种、税率的三张已审核订单。',
      'observations': [
        observation('one'),
        observation('two', day: 11, price: '12.8'),
        observation('three', day: 12, price: '12.6'),
      ],
      'costSummary': {
        'fullCostComplete': false,
        'actualFullCostComplete': false,
        'missingCostComponents': ['CONFIRMED_COST_REQUIRED'],
      },
    });

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  Future<(ProviderContainer, GoRouter)> pump(
    WidgetTester tester,
    _Repository repository, {
    Size size = const Size(1440, 1000),
    Set<String>? permissions,
    Widget? child,
  }) async {
    await loadAuditScreenshotFonts(tester);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/basicinfo/goods/a/price-analysis',
      routes: [
        GoRoute(
          path: '/basicinfo/goods/:id/price-analysis',
          builder: (_, s) =>
              child ?? GoodsPriceAnalysisPage(goodsId: s.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          priceAnalysisRepositoryProvider.overrideWithValue(repository),
          sessionProvider.overrideWith(_Session.new),
          if (permissions != null) _grants.overrideWith((_) => permissions),
          currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
          isSuperAdminProvider.overrideWithValue(false),
          apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
          sessionSnapshotProvider.overrideWith(_Snapshots.new),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: RepaintBoundary(
          key: const Key('price-page-visual'),
          child: MaterialApp.router(
            routerConfig: router,
            debugShowCheckedModeBanner: false,
            theme: auditScreenshotTheme(buildLightTheme()),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    return (
      ProviderScope.containerOf(
        tester.element(find.byKey(const Key('price-page-visual'))),
      ),
      router,
    );
  }

  testWidgets(
    'no analysis permission prevents both fetch and financial display',
    (tester) async {
      final repository = _Repository();
      await pump(
        tester,
        repository,
        permissions: {Perm.goodsView, Perm.goodsPriceView},
      );
      await tester.pumpAndSettle();
      expect(repository.queries, isEmpty);
      expect(find.text('需要货品查看与价格分析权限'), findsOneWidget);
      expect(find.byType(PriceHistoryChart), findsNothing);
    },
  );

  testWidgets('desktop shows real records and the declared reference basis', (
    tester,
  ) async {
    final repository = _Repository();
    await pump(tester, repository);
    await tester.pumpAndSettle();
    expect(find.byType(PriceHistoryChart), findsOneWidget);
    expect(find.text('≈12.3457'), findsOneWidget);
    expect(find.text('12.345678912345 人民币/个'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == '12.345678912345',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('按原记录税口径'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'price-desktop');
  });

  testWidgets(
    'mobile layout fits and records have a text alternative to the chart',
    (tester) async {
      await pump(tester, _Repository(), size: const Size(375, 844));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, 'price-mobile');
      await tester.ensureVisible(find.text('历史单据'));
      expect(find.byType(ListTile), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sales history does not assume a margin; entered 20 is sent as 0.2',
    (tester) async {
      final repository = _Repository();
      await pump(tester, repository);
      await tester.pumpAndSettle();
      await tester.tap(find.text('销售价格'));
      await tester.pumpAndSettle();
      expect(repository.queries.last['kind'], 'SALES');
      expect(repository.queries.last.containsKey('targetMarginRate'), isFalse);
      final margin = find.widgetWithText(TextField, '目标毛利率 %');
      await tester.enterText(margin, '20');
      await tester.tap(find.text('重新分析'));
      await tester.pumpAndSettle();
      expect(repository.queries.last['targetMarginRate'], '0.20');
      expect(find.textContaining('此处为已确认成本测算'), findsOneWidget);
    },
  );

  testWidgets(
    'permission revocation hides already rendered values and partner filters',
    (tester) async {
      final repository = _Repository();
      final (container, _) = await pump(tester, repository);
      await tester.pumpAndSettle();
      container.read(_grants.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.text('12.345678912345'), findsNothing);
      expect(find.text('测试供应商'), findsNothing);
      expect(find.byType(PriceHistoryChart), findsNothing);
    },
  );

  testWidgets('late goods response is discarded on route change', (
    tester,
  ) async {
    final repository = _Repository()..delay = true;
    final (_, router) = await pump(tester, repository);
    expect(repository.pending, hasLength(1));
    router.go('/basicinfo/goods/b/price-analysis');
    await tester.pump();
    await tester.pump();
    repository.pending.first.complete(sample(name: '旧货品机密'));
    await tester.pump();
    expect(find.textContaining('旧货品机密'), findsNothing);
    repository.pending.last.complete(sample(goodsId: 'b', name: '新货品'));
    await tester.pumpAndSettle();
    expect(find.textContaining('新货品'), findsOneWidget);
  });

  testWidgets(
    'stale or insufficient descriptive medians are not a current recommendation',
    (tester) async {
      final repository = _Repository()..status = 'STALE';
      await pump(tester, repository);
      await tester.pumpAndSettle();
      expect(find.text('12.345678912345'), findsNothing);
      expect(find.text('12.4'), findsOneWidget);
      expect(find.textContaining('现有依据不足'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(2));
    },
  );

  testWidgets('large mobile text and unavailable data remain usable', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repository = _Repository()..fail = true;
    await pump(tester, repository, size: const Size(375, 844));
    await tester.pumpAndSettle();
    expect(find.text('暂无法判断'), findsOneWidget);
    expect(tester.takeException(), isNull);
    repository.fail = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.byType(PriceHistoryChart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiny statistics stay one line with an exact accessible value', (
    tester,
  ) async {
    const tiny = '0.000000000000000123456789123456789';
    final repository = _Repository()
      ..overrides = {
        'referencePrice': tiny,
        'weightedAveragePrice': tiny,
        'lowerReferencePrice': tiny,
        'upperReferencePrice': tiny,
        'observations': [observation('tiny', price: tiny)],
      };
    await pump(tester, repository, size: const Size(375, 844));
    await tester.pumpAndSettle();
    expect(find.text('≈1.235e-16'), findsWidgets);
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == tiny),
      findsWidgets,
    );
    final summary = find.byKey(const ValueKey('price-summary-today'));
    final context = tester.element(summary);
    final label = tester.widget<PriceSummaryValue>(summary);
    final painter = TextPainter(
      text: TextSpan(
        text: label.compact,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(painter.width, lessThanOrEqualTo(tester.getSize(summary).width));
    painter.dispose();
    expect(find.text('0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editor batches invisible rows and hides an open evidence dialog on revoke',
    (tester) async {
      final repository = _Repository();
      final grid = UtenEditableGridController<PurchaseGridRow>();
      final row = PurchaseGridRow(supportsTotalInput: true)
        ..goods = const GoodsOption(id: 'g1', name: '料一')
        ..supplierId = 's1'
        ..currencyId = 'cny'
        ..unitId = 'piece'
        ..unitRate = 1;
      row.qty.text = '10';
      row.price.text = '12';
      row.taxRate.text = '13';
      final hidden = row.clone()
        ..goods = const GoodsOption(id: 'g2', name: '料二');
      grid.addRows([row, hidden]);
      addTearDown(grid.dispose);
      final (container, _) = await pump(
        tester,
        repository,
        child: ProcurementPriceCheckScope<PurchaseGridRow>(
          grid: grid,
          kind: 'PURCHASE',
          bindingOf: purchasePriceCheckBinding,
          child: Scaffold(
            body: SizedBox(
              width: 180,
              child: PriceCheckCell(
                row: row,
                child: TextField(controller: row.price),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      expect(repository.checkRequests.single, hasLength(2));
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.warning_amber_rounded));
      await tester.pumpAndSettle();
      expect(find.textContaining('10.25'), findsWidgets);
      container.read(_grants.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.textContaining('10.25'), findsNothing);
      expect(row.price.text, '12');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'quote-finance readers can open authorized history without sales analysis',
    (tester) async {
      final repository = _Repository();
      await pump(
        tester,
        repository,
        permissions: {
          Perm.goodsView,
          Perm.goodsPriceAnalysisView,
          Perm.materialCategoryView,
          Perm.salesQuoteFinanceView,
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('销售价格'));
      await tester.pumpAndSettle();
      expect(repository.queries.where((q) => q['kind'] == 'SALES'), isEmpty);
      expect(repository.historyQueries.last['kind'], 'SALES');
      expect(find.textContaining('仅可查看授权的财务确认报价历史'), findsOneWidget);
      expect(find.byType(PriceHistoryChart), findsNothing);
      expect(find.text('今日参考价格'), findsNothing);
    },
  );

  testWidgets(
    'history discovers frozen box conversion and safe colour labels without basic-unit prices',
    (tester) async {
      final repository = _Repository()
        ..status = 'INSUFFICIENT'
        ..overrides = {'observations': <Map<String, dynamic>>[]}
        ..historyRows = [
          {
            ...observation('box'),
            'unitId': 'box-id',
            'unitName': '箱',
            'unitRate': '24',
            'colorId': 'red-id',
            'colorName': '红色',
          },
        ];
      await pump(tester, repository);
      await tester.pumpAndSettle();
      final unit = tester.widget<DropdownButtonFormField<String>>(
        find.byWidgetPredicate(
          (w) =>
              w is DropdownButtonFormField<String> &&
              w.decoration.labelText == '单位',
        ),
      );
      unit.onChanged!('box-id|24');
      await tester.pumpAndSettle();
      expect(repository.queries.last['unitId'], 'box-id');
      expect(repository.queries.last['unitRate'], '24');
      expect(find.text('box-id'), findsNothing);
      expect(find.text('red-id'), findsNothing);
      final colour = tester.widget<DropdownButtonFormField<String>>(
        find.byWidgetPredicate(
          (w) =>
              w is DropdownButtonFormField<String> &&
              w.decoration.labelText == '颜色',
        ),
      );
      colour.onChanged!('red-id');
      await tester.pumpAndSettle();
      expect(repository.queries.last['colorId'], 'red-id');
    },
  );

  testWidgets('invalid margin reports margin when optional quantity is blank', (
    tester,
  ) async {
    final repository = _Repository();
    await pump(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('销售价格'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '目标毛利率 %'), '100');
    await tester.tap(find.text('重新分析'));
    await tester.pumpAndSettle();
    expect(find.text('毛利率须大于等于 0 且小于 100'), findsOneWidget);
    expect(find.text('数量须为大于 0 的有效数字'), findsNothing);
  });

  testWidgets(
    'refresh cancels a pending history cursor without locking its next load',
    (tester) async {
      final repository = _Repository();
      await pump(tester, repository);
      await tester.pumpAndSettle();
      repository.delayHistory = true;
      await tester.ensureVisible(find.text('查看全部历史'));
      await tester.tap(find.text('查看全部历史'));
      await tester.pump();
      expect(repository.pendingHistory, hasLength(1));
      await tester.tap(find.byTooltip('重新加载'));
      await tester.pumpAndSettle();
      repository.pendingHistory.first.complete(
        PriceHistoryPage({
          'observations': [observation('stale-history')],
          'hasMore': false,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('PO-stale-history'), findsNothing);
      await tester.ensureVisible(find.text('查看全部历史'));
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('查看全部历史'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNotNull);
      for (final pending in repository.pendingHistory.skip(1)) {
        if (!pending.isCompleted) {
          pending.complete(
            PriceHistoryPage({
              'observations': <Map<String, dynamic>>[],
              'hasMore': false,
            }),
          );
        }
      }
      await tester.pumpAndSettle();
    },
  );

  test(
    'statistic formatting never truncates the exact financial formatter',
    () {
      expect(compactPriceStatistic('12.345678912345'), '≈12.3457');
      expect(compactPriceStatistic('12.4'), '12.4');
      expect(compactPriceStatistic('0.000000000000000123456789'), '≈1.235e-16');
      expect(compactPriceStatistic('12340000000'), '≈1.234e10');
      expect(compactPriceStatistic('999999.9'), '≈1e6');
      expect(compactPriceStatistic(null), '—');
      expect(
        compactPriceRange('0.0000000000000001234', '12340000000').length,
        lessThanOrEqualTo(15),
      );
      expect(priceNumber('12.345678912345'), '12.345678912345');
    },
  );

  testWidgets(
    'summary focus reveals full precision and screen-reader labels retain it',
    (tester) async {
      final semantics = tester.ensureSemantics();

      await pump(tester, _Repository(), size: const Size(375, 844));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(r'今日参考价格: 12\.345678912345')),
        findsWidgets,
      );
      Focus.of(tester.element(find.text('≈12.3457'))).requestFocus();
      await tester.pumpAndSettle();
      expect(find.text('12.345678912345'), findsWidgets);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('full history uses cursors and retains each original record', (
    tester,
  ) async {
    final repository = _Repository();
    await pump(tester, repository);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看全部历史'));
    await tester.tap(find.text('查看全部历史'));
    await tester.pumpAndSettle();
    expect(repository.historyQueries, hasLength(2));
    await tester.ensureVisible(find.text('更多记录'));
    await tester.tap(find.text('更多记录'));
    await tester.pumpAndSettle();
    expect(repository.historyQueries.last['cursor'], 'cursor');
    expect(find.text('PO-archived-1'), findsOneWidget);
    expect(find.text('PO-archived-2'), findsOneWidget);
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('UTEN_PRICE_VISUAL_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('price-page-visual')),
    );
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
