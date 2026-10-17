import 'dart:convert';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/components/layout/uten_segmented_filter.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_price_facet_picker.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_subcontract_supplier_table.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_price_observation_detail.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:dio/dio.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:flutter/gestures.dart';
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
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import '../../../support/audit_screenshot_support.dart';
import 'package:uten_imp/features/basic_data/pages/goods_price_analysis_page.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_price_history_chart.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/pricing/price_analysis_models.dart';
import 'package:uten_imp/shared/pricing/price_analysis_l10n.dart';
import 'package:uten_imp/shared/pricing/price_summary_value.dart';

import 'package:uten_imp/shared/pricing/price_analysis_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// Match the component's nullable value contract. ValueKey compares runtimeType,
// so an inferred record with a literal String/Null is a different key type.
ValueKey<(String, Key?, String?)> _dropdownOptionKey(
  Key? fieldKey,
  String? value,
) => ValueKey<(String, Key?, String?)>((
  'uten-dropdown-option',
  fieldKey,
  value,
));

final _grants = StateProvider<Set<String>>(
  (_) => {
    Perm.goodsView,
    Perm.goodsPriceAnalysisView,
    Perm.materialCategoryView,
  },
);

class _PriceNonlinearScaler extends TextScaler {
  const _PriceNonlinearScaler();
  @override
  double scale(double fontSize) =>
      fontSize < 24 ? fontSize * 2 : fontSize * 1.4;
  @override
  double get textScaleFactor => 2;
}

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
  final tableQueries = <Map<String, dynamic>>[];
  final facetQueries = <Map<String, dynamic>>[];
  final supplierQueries = <Map<String, dynamic>>[];
  final pendingTables = <Completer<PagedResult<PriceObservation>>>[];
  bool supplierApplicable = false, highCardinality = false;
  Map<String, dynamic> supplierResponse = {'applicable': false};
  bool delaySupplierDetail = false;
  final pendingSupplierDetails = <Completer<Map<String, dynamic>>>[];
  final pending = <Completer<GoodsPriceAnalysis>>[];
  final pendingHistory = <Completer<PriceHistoryPage>>[];
  bool delayHistory = false;
  bool delayDetail = false;
  ApiException? detailFailure;
  final detailQueries = <PriceObservation>[];
  final pendingDetails = <Completer<PriceObservationDetail>>[];
  final checkRequests = <List<Map<String, dynamic>>>[];
  Map<String, dynamic> overrides = {};
  Map<String, dynamic> checkOverrides = {};
  List<Map<String, dynamic>>? historyRows;
  bool delay = false;
  String status = 'READY';
  bool fail = false;
  @override
  Future<bool> subcontractApplicable(String goodsId) async =>
      supplierApplicable;
  @override
  Future<Map<String, dynamic>> subcontractSuppliers(
    String goodsId,
    Map<String, dynamic> query,
  ) async {
    supplierQueries.add(query);
    if (delaySupplierDetail && query['supplierId'] != null) {
      final pending = Completer<Map<String, dynamic>>();
      pendingSupplierDetails.add(pending);
      return pending.future;
    }
    return supplierResponse;
  }

  @override
  Future<Map<String, dynamic>> historyFacets(
    String goodsId,
    Map<String, dynamic> query,
  ) async {
    facetQueries.add(query);
    return {
      'column': query['column'],
      'buckets': [
        {'value': 'PO-201', 'label': '第201条单据', 'count': 1},
      ],
      'page': query['page'] ?? 1,
      'size': 50,
      'total': 1,
      'totalPages': 1,
      'nullCount': 0,
      'hasMore': false,
    };
  }

  @override
  Future<PagedResult<PriceObservation>> historyTable(
    String goodsId,
    Map<String, dynamic> query,
  ) async {
    tableQueries.add(Map<String, dynamic>.from(query));
    if (delayHistory) {
      final c = Completer<PagedResult<PriceObservation>>();
      pendingTables.add(c);
      return c.future;
    }
    final filters = priceMap(jsonDecode(query['filters']?.toString() ?? '{}'));
    final rows = historyRows ?? [observation('archived-${query['page'] ?? 1}')];
    return PriceHistoryTableResult.fromResponse({
      'observations': highCardinality && filters['sourceNo'] == 'PO-201'
          ? [
              {...observation('201'), 'sourceNo': 'PO-201'},
            ]
          : rows,
      'page': query['page'] ?? 1,
      'size': 50,
      'total': highCardinality ? (filters.isEmpty ? 201 : 1) : 100,
      'totalPages': highCardinality ? (filters.isEmpty ? 5 : 1) : 2,
      'facets': {
        'sourceNo': [
          {'value': 'PO-initial', 'label': '初始单据', 'count': 1},
        ],
        'amount': [
          {'value': '1234.5678912345', 'count': 2},
        ],
      },
      'nullCounts': {'colorName': 2},
      'facetTotals': {'sourceNo': 201},
      'facetsHasMore': {'sourceNo': highCardinality},
    });
  }

  @override
  Future<PriceObservationDetail> detail(
    String goodsId,
    String kind,
    PriceObservation row,
  ) async {
    detailQueries.add(row);
    if (detailFailure != null) throw detailFailure!;
    if (delayDetail) {
      final c = Completer<PriceObservationDetail>();
      pendingDetails.add(c);
      return c.future;
    }
    return verifiedDetail(row);
  }

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
          ...checkOverrides,
        }),
    ];
  }
}

PriceObservationDetail verifiedDetail(PriceObservation row) =>
    PriceObservationDetail({
      'observation': row.data,
      'title': '价格详情',
      'summary': row.text('historyVersionId').isEmpty
          ? '已核对的原始记录'
          : '历史审核版本，仅供追溯',
      'fields': [
        {'key': 'sourceNo', 'label': '原单编号', 'value': row.text('sourceNo')},
        {'key': 'unitPrice', 'label': '本行折合单价', 'value': row.price},
        {'key': 'evidence', 'label': '核对说明', 'value': '服务端已确认当前可见版本'},
        for (final field in [
          ('businessDate', '单据日期'),
          ('partnerName', '往来单位'),
          ('quantity', '计价数量'),
          ('amount', '原币金额'),
          ('unitName', '计价单位'),
          ('currencyName', '币种'),
          ('taxRate', '税率%'),
        ])
          {'key': field.$1, 'label': field.$2, 'value': row.data[field.$1]},
      ],
      'reasonCodes': <String>[],
    });

Map<String, dynamic> observation(
  String id, {
  int day = 10,
  String price = '12.345678912345',
}) => {
  'sourceRevision': 'revision-$id',
  'sourceId': id,
  'sourceItemId': 'item-$id',
  'sourceType': 'PURCHASE_ORDER',
  'sourceNo': 'PO-$id',
  'businessDate': '2026-10-${day.toString().padLeft(2, '0')}',
  'partnerName': '测试供应商',
  'supplierId': 'supplier',
  'quantity': '100',
  'unitPrice': price,
  'amount': switch (price) {
    '12.8' => '1280',
    '12.6' => '1260',
    _ => '1234.5678912345',
  },
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
    final previousHitPolicy = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(
      () => WidgetController.hitTestWarningShouldBeFatal = previousHitPolicy,
    );
    UtenBusyOverlay.debugResetYield();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  Future<(ProviderContainer, GoRouter)> pump(
    WidgetTester tester,
    _Repository repository, {
    Size size = const Size(1440, 1000),
    Set<String>? permissions,
    Widget? child,
    double factor = 1,
    TextScaler? scaler,
    Locale locale = const Locale('zh'),
  }) async {
    await loadAuditScreenshotFonts(tester);
    final koreanFont = locale.languageCode == 'ko'
        ? await loadAuditKoreanScreenshotFont(
            tester,
            requiredForCapture: const String.fromEnvironment(
              'UTEN_PRICE_VISUAL_DIR',
            ).isNotEmpty,
          )
        : null;
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
            theme: auditScreenshotTheme(
              buildLightTheme(),
              fontFamilyFallback: koreanFont == null ? null : [koreanFont],
            ),
            builder: (context, routed) => MediaQuery(
              data: scaler == null
                  ? MediaQuery.of(context)
                  : MediaQuery.of(context).copyWith(textScaler: scaler),
              child: UtenDisplayZoomBox(
                fontFactor: factor,
                child: UtenControlTheme(child: routed!),
              ),
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
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

  Future<void> scrollToRows(WidgetTester tester) async {
    for (
      var i = 0;
      i < 5 &&
          find.byKey(const Key('goods-price-history-table')).evaluate().isEmpty;
      i++
    ) {
      await tester.drag(
        find.byType(UtenCollapsingHeaderScrollView),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> openRow(WidgetTester tester, String number) async {
    await scrollToRows(tester);
    await tester.ensureVisible(find.text(number));
    await tester.tap(find.text(number));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text(number));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  testWidgets(
    'price pressure: narrow controls keep full selections and original queries',
    (tester) async {
      final repository = _Repository();
      await pump(
        tester,
        repository,
        size: const Size(320, 640),
        factor: 2,
        scaler: const _PriceNonlinearScaler(),
      );
      await tester.pumpAndSettle();
      final days = find.byKey(const ValueKey('price-analysis-days'));
      await tester.ensureVisible(days);
      await tester.pumpAndSettle();
      final daysWidget = tester.widget<UtenDropdownField>(days);
      expect(daysWidget.selectedMaxLines, isNull);
      expect(tester.getRect(days).width, closeTo(272, 1e-6));
      await tester.tap(days);
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('365天').last),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      final optionRect = tester.getRect(find.text('365天').last);
      expect(optionRect.top, greaterThanOrEqualTo(0));
      expect(optionRect.bottom, lessThanOrEqualTo(640));
      await tester.tap(find.text('365天').last);
      await tester.pumpAndSettle();
      expect(repository.queries.last['days'], 365);
      expect(tester.widget<UtenDropdownField>(days).value, '365');
      final visibleDay = find.descendant(of: days, matching: find.text('365天'));
      expect(tester.widget<Text>(visibleDay).maxLines, isNull);
      final quantity = find.byKey(const ValueKey('price-analysis-quantity'));
      await tester.ensureVisible(quantity);
      await tester.pumpAndSettle();
      await tester.enterText(quantity, '12345.6789');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repository.queries.last['quantity'], '12345.6789');
      expect(tester.widget<TextField>(quantity).controller!.text, '12345.6789');
      await tester.ensureVisible(find.text('更多筛选'));
      await tester.pumpAndSettle();
      final filterRect = tester.getRect(find.text('更多筛选'));
      expect(filterRect.top, greaterThanOrEqualTo(0));
      expect(filterRect.bottom, lessThanOrEqualTo(640));
      await tester.tap(find.text('更多筛选'));
      await tester.pumpAndSettle();
      final choices = find.byWidgetPredicate(
        (widget) => widget is UtenDropdownField && widget.label != '历史期间',
      );
      expect(choices, findsWidgets);
      for (final element in choices.evaluate()) {
        final widget = element.widget as UtenDropdownField;
        expect(widget.selectedMaxLines, isNull);
        expect(
          (element.findRenderObject()! as RenderBox).size.width,
          closeTo(136, 1e-6),
        );
      }
      expect(tester.takeException(), isNull);
      await _capture(tester, 'price-pressure-320-2x-nonlinear-controls');
    },
  );

  testWidgets(
    'price pressure: nonlinear chart axes pan without dropping facts',
    (tester) async {
      const scaler = _PriceNonlinearScaler();
      final facts = [
        observation('large-one', price: '999999999.123456'),
        observation('large-two', price: '999999999.223456', day: 12),
      ];
      final analysis = GoodsPriceAnalysis({
        ...sample().data,
        'observations': facts,
        'referencePrice': '999999999.123456',
        'lowerReferencePrice': '999999999.1',
        'upperReferencePrice': '999999999.3',
      });
      await pump(
        tester,
        _Repository(),
        size: const Size(320, 640),
        factor: 2,
        scaler: scaler,
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: PriceHistoryChart(analysis: analysis),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final chart = find.byKey(const ValueKey('price-history-chart-canvas'));
      final referenceLabel = find.text('参考线');
      final referenceParagraph = tester.renderObject<RenderParagraph>(
        referenceLabel,
      );
      expect(referenceParagraph.maxLines, isNull);
      expect(referenceParagraph.text.toPlainText(), '参考线');
      expect(referenceParagraph.overflow, TextOverflow.clip);
      final lastGlyph = referenceParagraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 2, extentOffset: 3),
          )
          .single;
      expect(
        lastGlyph.right,
        lessThanOrEqualTo(referenceParagraph.size.width + 1e-6),
      );
      expect(
        lastGlyph.bottom,
        lessThanOrEqualTo(referenceParagraph.size.height + 1e-6),
      );
      final reference = tester.widget<FilterChip>(
        find.ancestor(of: referenceLabel, matching: find.byType(FilterChip)),
      );
      expect(reference.selected, isTrue);
      final paint = tester.widget<CustomPaint>(chart);
      final painter = paint.painter! as PriceHistoryPainter;
      expect(painter.textScaler, same(scaler));
      expect(painter.points.length, 2);
      final chartSize = tester.getSize(chart);
      final geometry = painter.layout(chartSize);
      final rect = geometry.$1;
      expect(rect.left, greaterThanOrEqualTo(64));
      final style = painter.textStyle;
      TextPainter label(String value) => TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final low = geometry.$4, high = geometry.$5;
      for (var i = 0; i <= 3; i++) {
        final value = low + (high - low) * i / 3;
        final tick = label(
          value.abs() >= 1000000000
              ? value.toStringAsExponential(2)
              : value.toStringAsFixed(2),
        );
        expect(rect.left - 8 - tick.width, greaterThanOrEqualTo(0));
        tick.dispose();
      }
      final start = label('2026-10-10'), end = label('2026-10-12');
      expect(
        rect.left + start.width,
        lessThanOrEqualTo(rect.right - end.width),
      );
      start.dispose();
      end.dispose();
      final scrollable = find.descendant(
        of: find.byType(PriceHistoryChart),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.right,
        ),
      );
      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.maxScrollExtent, greaterThan(0));
      expect(
        find.descendant(
          of: find.byType(PriceHistoryChart),
          matching: find.byType(Scrollbar),
        ),
        findsOneWidget,
      );
      final point = painter.points.last;
      final position = painter.position(point, chartSize);
      await Scrollable.ensureVisible(tester.element(chart));
      await tester.pumpAndSettle();
      state.position.jumpTo(
        (position.dx - 70).clamp(0, state.position.maxScrollExtent),
      );
      await tester.pump();
      final box = tester.renderObject<RenderBox>(chart);
      final pointOnScreen = box.localToGlobal(position);
      expect(pointOnScreen.dx, inInclusiveRange(0, 320));
      expect(pointOnScreen.dy, inInclusiveRange(0, 640));
      await tester.tapAt(pointOnScreen);
      await tester.pump();
      expect(find.textContaining('PO-large-two'), findsOneWidget);
      expect(find.textContaining('999999999.223456'), findsOneWidget);
      expect(analysis.data['observations'], same(facts));
      expect(tester.takeException(), isNull);
      await _capture(tester, 'price-pressure-320-2x-nonlinear-chart');
    },
  );

  for (final scenario in [
    (const Size(390, 1000), .85),
    (const Size(640, 320), 2.0),
  ]) {
    testWidgets(
      'price pressure: evidence target and short dialog preserve raw price $scenario',
      (tester) async {
        final repository = _Repository()
          ..checkOverrides = {
            'message': '完整服务端核对依据：' * 30,
            'referencePrice': '123456.789123456',
          };
        final row = PurchaseGridRow(supportsTotalInput: true)
          ..goods = const GoodsOption(id: 'g1', name: '原始料')
          ..supplierId = 's1'
          ..currencyId = 'cny'
          ..unitId = 'piece'
          ..unitRate = 1;
        row.qty.text = '10';
        row.price.text = '123456.789123456';
        row.taxRate.text = '13';
        final grid = UtenEditableGridController<PurchaseGridRow>(
          initial: [row],
        );
        addTearDown(grid.dispose);
        final (container, _) = await pump(
          tester,
          repository,
          size: scenario.$1,
          factor: scenario.$2,
          scaler: const _PriceNonlinearScaler(),
          child: ProcurementPriceCheckScope<PurchaseGridRow>(
            grid: grid,
            kind: 'PURCHASE',
            bindingOf: purchasePriceCheckBinding,
            child: Scaffold(
              body: PriceCheckCell(
                row: row,
                child: TextField(controller: row.price),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 301));
        await tester.pump();
        final evidence = find.byKey(
          const ValueKey('price-evidence-price-row-1'),
        );
        final bounds = tester.getRect(evidence);
        expect(bounds.width, greaterThanOrEqualTo(48 - 1e-6));
        expect(bounds.height, greaterThanOrEqualTo(48 - 1e-6));
        await tester.tapAt(Offset(bounds.right - 2, bounds.center.dy));
        await tester.pumpAndSettle();
        expect(find.byType(UtenAlertDialog), findsOneWidget);
        expect(find.textContaining('123456.789123456'), findsWidgets);
        expect(row.price.text, '123456.789123456');
        expect(
          repository.checkRequests.single.single['unitPrice'],
          '123456.789123456',
        );
        container.read(_grants.notifier).state = {Perm.goodsView};
        await tester.pumpAndSettle();
        expect(
          find.textContaining('123456.789123456'),
          findsOneWidget,
          reason:
              'only the employee\'s own unchanged input remains after revocation',
        );
        final close = find.text('关闭');
        await tester.ensureVisible(close);
        await tester.pumpAndSettle();
        final closeBounds = tester.getRect(close);
        expect(closeBounds.top, greaterThanOrEqualTo(0));
        expect(closeBounds.bottom, lessThanOrEqualTo(scenario.$1.height));
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(UtenAlertDialog), findsNothing);
        expect(row.price.text, '123456.789123456');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final locale in [const Locale('en'), const Locale('ko')]) {
    testWidgets(
      'price pressure: complete basis and close are reachable in short 2x $locale',
      (tester) async {
        const originalCost = '完整成本版本依据，不构成最终报价；保持服务端原文。';
        final repository = _Repository()
          ..overrides = {
            'explanation': 'Original recorded transaction basis. ' * 30,
            'reasonCodes': ['SUPPLIER_SCOPE_FALLBACK', 'OUTDATED'],
            'costSummary': {...sample().cost, 'explanation': originalCost},
          };
        await pump(
          tester,
          repository,
          size: const Size(640, 320),
          factor: 2,
          scaler: const _PriceNonlinearScaler(),
          locale: locale,
        );
        await tester.pumpAndSettle();
        final pageContext = tester.element(find.byType(GoodsPriceAnalysisPage));
        final basis = find.text(priceText(pageContext, 'explain'));
        await tester.ensureVisible(basis);
        await tester.pumpAndSettle();
        final queryCount = repository.queries.length;
        await tester.tap(basis);
        await tester.pumpAndSettle();
        final scroll = find.byKey(const ValueKey('price-basis-scroll'));
        expect(scroll, findsOneWidget);
        final reasons = find.byKey(const ValueKey('price-basis-reasons'));
        await Scrollable.ensureVisible(tester.element(reasons), alignment: 1);
        await tester.pumpAndSettle();
        final viewport = tester.getRect(scroll);
        final reasonsRect = tester.getRect(reasons);
        expect(reasonsRect.bottom, lessThanOrEqualTo(viewport.bottom + 1e-6));
        expect(reasonsRect.bottom, greaterThan(viewport.top));
        expect(
          tester.widget<Text>(reasons).data,
          [
            priceText(pageContext, 'SUPPLIER_SCOPE_FALLBACK'),
            priceText(pageContext, 'OUTDATED'),
          ].join(' · '),
        );
        final footer = find.byKey(const ValueKey('price-basis-chart-hint'));
        await Scrollable.ensureVisible(tester.element(footer), alignment: 1);
        await tester.pumpAndSettle();
        final footerRect = tester.getRect(footer);
        expect(footerRect.bottom, lessThanOrEqualTo(viewport.bottom + 1e-6));
        expect(footerRect.bottom, greaterThan(viewport.top));
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('price-basis-cost-explanation')),
              )
              .data,
          originalCost,
        );
        await _capture(
          tester,
          'price-pressure-basis-short-2x-${locale.languageCode}',
        );
        final close = find.byKey(const ValueKey('price-basis-close'));
        await tester.ensureVisible(close);
        await tester.pumpAndSettle();
        final bounds = tester.getRect(close);
        expect(bounds.width, greaterThanOrEqualTo(48));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(320));
        await tester.tapAt(Offset(bounds.right - 2, bounds.center.dy));
        await tester.pumpAndSettle();
        expect(scroll, findsNothing);
        expect(repository.queries.length, queryCount);
        expect(tester.takeException(), isNull);
      },
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
    expect(find.textContaining('≈12.3457'), findsOneWidget);
    expect(
      tester
          .widget<MasterDataTableView<PriceObservation>>(
            find.byKey(const Key('goods-price-history-table')),
          )
          .columns
          .firstWhere((c) => c.key == 'unitPrice')
          .value(PriceObservation(observation('one'))),
      '12.345678912345',
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == '12.345678912345',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('基于相同单位'), findsNothing);
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
      await scrollToRows(tester);
      final table = tester.widget<MasterDataTableView<PriceObservation>>(
        find.byKey(const Key('goods-price-history-table')),
      );
      expect(table.virtualized, isTrue);
      expect(table.embedded, isFalse);
      expect(table.primary, isTrue);
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
      expect(find.text('确认测算口径，非实际全成本'), findsOneWidget);
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
      expect(
        tester
            .widget<PriceSummaryValue>(
              find.byKey(const ValueKey('price-summary-today')),
            )
            .compact,
        '—',
      );
      expect(find.textContaining('12.4 人民币'), findsOneWidget);
      expect(find.textContaining('历史价格较旧'), findsOneWidget);
      expect(
        tester
            .widget<PriceSummaryValue>(
              find.byKey(const ValueKey('price-summary-range')),
            )
            .compact,
        '—',
      );
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
    expect(find.textContaining('≈1.235e-16'), findsWidgets);
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
      expect(repository.tableQueries.last['kind'], 'SALES');
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
      await tester.tap(find.text('更多筛选'));
      await tester.pumpAndSettle();
      final unit = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '单位',
      );
      await Scrollable.ensureVisible(tester.element(unit), alignment: 0.5);
      await tester.pumpAndSettle();
      final unitField = tester.widget<UtenDropdownField>(unit);
      final boxOption = unitField.items.singleWhere(
        (option) => option.value == 'box-id|24',
      );
      expect(boxOption.label, '箱 ×24');
      final unitArrow = find.descendant(
        of: unit,
        matching: find.byIcon(Icons.arrow_drop_down_rounded),
      );
      expect(unitArrow, findsOneWidget);
      await tester.tap(unitArrow);
      await tester.pumpAndSettle();
      final box = find.byKey(
        _dropdownOptionKey(unitField.key, boxOption.value),
      );
      expect(box, findsOneWidget);
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(repository.queries.last['unitId'], 'box-id');
      expect(repository.queries.last['unitRate'], '24');
      expect(find.text('box-id'), findsNothing);
      expect(find.text('red-id'), findsNothing);
      final colour = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '颜色',
      );
      // Selecting a frozen unit reloads analysis and can reflow the collapsing
      // controls. Read the current colour field after revealing its whole anchor.
      await Scrollable.ensureVisible(tester.element(colour), alignment: 0.5);
      await tester.pumpAndSettle();
      final colorField = tester.widget<UtenDropdownField>(colour);
      final redOption = colorField.items.singleWhere(
        (option) => option.value == 'red-id',
      );
      expect(redOption.label, '红色');
      expect(redOption.enabled && redOption.visible, isTrue);
      final colorArrow = find.descendant(
        of: colour,
        matching: find.byIcon(Icons.arrow_drop_down_rounded),
      );
      expect(colorArrow, findsOneWidget);
      await tester.tap(colorArrow);
      await tester.pumpAndSettle();
      final red = find.byKey(
        _dropdownOptionKey(colorField.key, redOption.value),
      );
      final automatic = find.byKey(_dropdownOptionKey(colorField.key, null));
      expect(
        automatic,
        findsOneWidget,
        reason: 'the current colour field must open its own choices',
      );
      expect(red.hitTestable(), findsOneWidget);
      await tester.tap(red);
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
    'refresh supersedes pending server history and keeps its query usable',
    (tester) async {
      final repository = _Repository();
      await pump(tester, repository);
      await tester.pumpAndSettle();
      repository.delayHistory = true;
      await tester.ensureVisible(find.text('查看全部历史'));
      await tester.tap(find.text('查看全部历史'));
      await tester.pump();
      expect(repository.pendingTables, hasLength(1));
      tester
          .widget<UtenAppBarActionButton>(
            find.byWidgetPredicate(
              (w) => w is UtenAppBarActionButton && w.tooltip == '重新加载',
            ),
          )
          .onPressed!();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      repository.pendingTables.first.complete(
        PriceHistoryTableResult.fromResponse({
          'observations': [observation('stale-history')],
          'page': 1,
          'totalPages': 1,
        }),
      );
      await tester.pump();
      expect(find.text('PO-stale-history'), findsNothing);
      repository.pendingTables.last.complete(
        PriceHistoryTableResult.fromResponse({
          'observations': [observation('fresh-history')],
          'page': 1,
          'totalPages': 1,
        }),
      );
      for (final pending in repository.pendingHistory) {
        if (!pending.isCompleted) {
          pending.complete(
            PriceHistoryPage({'observations': <Map<String, dynamic>>[]}),
          );
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        tester
            .widget<MasterDataTableView<PriceObservation>>(
              find.byKey(const Key('goods-price-history-table')),
            )
            .items
            .single
            .text('sourceNo'),
        'PO-fresh-history',
      );
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
      Focus.of(tester.element(find.textContaining('≈12.3457'))).requestFocus();
      await tester.pumpAndSettle();
      expect(find.text('12.345678912345'), findsWidgets);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'shared table double click reads the exact historical version with a sensitive detail column',
    (tester) async {
      final old = {
        ...observation('old'),
        'sourceType': 'PURCHASE_ORDER_APPROVAL',
        'historyVersionId': 'history-v1',
        'lifecycle': 'SUPERSEDED_APPROVED_VERSION',
        'comparable': false,
      };
      final other = {...old, 'historyVersionId': 'history-v2'};
      final repository = _Repository()
        ..delayDetail = true
        ..overrides = {
          'observations': [old, other],
        };
      await pump(tester, repository);
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<PriceObservation>>(
        find.byKey(const Key('goods-price-history-table')),
      );
      expect(
        table.rowKeyOf!(table.items[0]),
        isNot(table.rowKeyOf!(table.items[1])),
      );
      expect(
        table.columns
            .where((c) => c.key == 'unitPrice' || c.key == 'amount')
            .every((c) => c.aiSensitive),
        isTrue,
      );
      // Activate the actual shared row twice, distinguishing identical document numbers by version key.
      final first = find.byKey(
        ValueKey('price-history-${PriceObservation(old).identity}'),
      );
      await tester.ensureVisible(first);
      await tester.tap(first);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(first);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(repository.detailQueries, hasLength(1));
      expect(
        repository.detailQueries.single.text('historyVersionId'),
        'history-v1',
      );
      expect(find.text('正在读取价格详情'), findsOneWidget);
      await _capture(tester, 'price-loading');
      expect(find.text('服务端已确认当前可见版本'), findsNothing);
      repository.pendingDetails.single.complete(
        verifiedDetail(PriceObservation(old)),
      );
      await tester.pumpAndSettle();
      expect(find.text('服务端已确认当前可见版本'), findsOneWidget);
      expect(find.text('查看原单'), findsNothing);
      final detailTable = tester
          .widget<MasterDataTableView<Map<String, dynamic>>>(
            find.byType(MasterDataTableView<Map<String, dynamic>>),
          );
      expect(
        detailTable.columns.singleWhere((c) => c.key == 'value').aiSensitive,
        isTrue,
      );
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await _capture(tester, 'price-detail-desktop');
    },
  );

  testWidgets(
    'closing pending detail removes the shared loading overlay and discards its late response',
    (tester) async {
      final repository = _Repository()..delayDetail = true;
      await pump(tester, repository);
      await tester.pumpAndSettle();
      await openRow(tester, 'PO-one');
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      Navigator.of(
        tester.element(find.byType(GoodsPriceObservationDetail)),
      ).pop();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      repository.pendingDetails.single.complete(
        verifiedDetail(repository.detailQueries.single),
      );
      await tester.pumpAndSettle();
      expect(find.text('服务端已确认当前可见版本'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission switch hides pending detail and clears shared loading',
    (tester) async {
      final repository = _Repository()..delayDetail = true;
      final (container, _) = await pump(tester, repository);
      await tester.pumpAndSettle();
      await openRow(tester, 'PO-one');
      container.read(_grants.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      repository.pendingDetails.single.complete(
        verifiedDetail(repository.detailQueries.single),
      );
      await tester.pumpAndSettle();
      expect(find.text('服务端已确认当前可见版本'), findsNothing);
      expect(find.byType(UtenBusyOverlay), findsNothing);
    },
  );

  testWidgets(
    'a changed detail asks to reload history and never shows the cached row as verified',
    (tester) async {
      final repository = _Repository()
        ..detailFailure = ApiException(
          'CONFLICT',
          '价格版本已变化，请重新加载历史',
          httpStatus: 409,
        );
      await pump(tester, repository);
      await tester.pumpAndSettle();
      await openRow(tester, 'PO-one');
      await tester.pumpAndSettle();
      expect(find.text('价格版本已变化，请重新加载历史'), findsOneWidget);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('服务端已确认当前可见版本'), findsNothing);
      repository.detailFailure = null;
      await tester.tap(find.text('重新加载历史'));
      await tester.pumpAndSettle();
      expect(find.byType(GoodsPriceObservationDetail), findsNothing);
      expect(repository.queries.length, greaterThan(1));
    },
  );

  testWidgets(
    'detail source action also requires the current document-route grant',
    (tester) async {
      final repository = _Repository()
        ..overrides = {
          'observations': [
            {...observation('one'), 'canOpenSource': true},
          ],
        };
      await pump(tester, repository, size: const Size(375, 844));
      await tester.pumpAndSettle();
      await openRow(tester, 'PO-one');
      await tester.pumpAndSettle();
      expect(find.text('服务端已确认当前可见版本'), findsOneWidget);
      expect(find.text('查看原单'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'price-detail-mobile');
    },
  );

  testWidgets(
    'analysis failure removes shared network loading and leaves a retry',
    (tester) async {
      final repository = _Repository()..delay = true;
      await pump(tester, repository);
      await tester.pump();
      expect(find.text('正在分析价格'), findsOneWidget);
      repository.pending.single.completeError(ApiException('NETWORK', '读取失败'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('读取失败'), findsOneWidget);
    },
  );

  testWidgets(
    'reference line toggles without hiding recorded transaction trend',
    (tester) async {
      await pump(tester, _Repository());
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(FilterChip, '参考线');
      expect(tester.widget<FilterChip>(toggle).selected, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<FilterChip>(toggle).selected, isFalse);
      expect(find.text('成交走势'), findsOneWidget);
      expect(find.byType(PriceHistoryChart), findsOneWidget);
    },
  );

  for (final fallback in [false, true]) {
    testWidgets(
      'peer price warning exposes the real comparison basis (fallback=$fallback)',
      (tester) async {
        final repository = _Repository()
          ..checkOverrides = {
            'referencePrice': fallback ? '50' : '100',
            'weightedAveragePrice': fallback ? '50' : '100',
            'percentageDeviation': fallback ? '100' : '0',
            'estimatedImpact': fallback ? '500' : '0',
            'currencyName': '人民币',
            'unitName': '个',
            'peerReferencePrice': '50',
            'peerPercentageDeviation': '100',
            'reasonCodes': [
              'PEER_PRICE_ABOVE_REFERENCE',
              if (fallback) 'SUPPLIER_SCOPE_FALLBACK',
            ],
            'message': '完整算法说明（仅展开）',
          };
        final row = PurchaseGridRow(supportsTotalInput: true)
          ..goods = const GoodsOption(id: 'goods', name: '测试货品')
          ..supplierId = 'supplier'
          ..currencyId = 'cny'
          ..unitId = 'unit'
          ..unitRate = 1;
        row.qty.text = '10';
        row.price.text = '100';
        row.taxRate.text = '13';
        final grid = UtenEditableGridController<PurchaseGridRow>()..addRow(row);
        addTearDown(grid.dispose);
        await pump(
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
        await tester.tap(find.byIcon(Icons.warning_amber_rounded));
        await tester.pumpAndSettle();
        expect(find.textContaining('同条件供应商参考: 50 人民币/个'), findsWidgets);
        expect(find.text('完整算法说明（仅展开）'), findsNothing);
        if (fallback) {
          expect(find.textContaining('本供应商样本不足'), findsWidgets);
          expect(find.textContaining('本供应商参考: 50'), findsNothing);
        } else {
          expect(find.textContaining('本供应商参考: 100'), findsWidgets);
          expect(find.textContaining('对应偏差: 100%'), findsWidgets);
        }
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final size in [const Size(1440, 1000), const Size(375, 844)]) {
    testWidgets(
      'revoked detail can close without returning a false source ($size)',
      (tester) async {
        final repository = _Repository();
        final (container, _) = await pump(tester, repository, size: size);
        await tester.pumpAndSettle();
        await openRow(tester, 'PO-one');
        await tester.pumpAndSettle();
        expect(find.byType(GoodsPriceObservationDetail), findsOneWidget);
        container.read(_grants.notifier).state = {Perm.goodsView};
        await tester.pumpAndSettle();
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(GoodsPriceObservationDetail), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'facet search beyond the first 200 values remains selected and can be cleared',
    (tester) async {
      final repository = _Repository()..highCardinality = true;
      await pump(tester, repository);
      await tester.pumpAndSettle();
      await scrollToRows(tester);
      await tester.ensureVisible(find.text('查看全部历史'));
      await tester.tap(find.text('查看全部历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部筛选值'));
      await tester.pumpAndSettle();
      expect(find.byType(GoodsPriceFacetPicker), findsOneWidget);
      final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '搜索全部可见取值',
      );
      await tester.enterText(search, '201');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(repository.facetQueries.last['search'], '201');
      await tester.tap(find.text('第201条单据'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<PriceObservation>>(
        find.byKey(const Key('goods-price-history-table')),
      );
      expect(table.filters['sourceNo'], 'PO-201');
      final selected = table.facets['sourceNo']!.singleWhere(
        (bucket) => bucket.value == 'PO-201',
      );
      expect(selected.display, '第201条单据');
      expect(selected.count, 1);
      table.onFilterChanged('sourceNo', null);
      await tester.pumpAndSettle();
      final cleared = tester.widget<MasterDataTableView<PriceObservation>>(
        find.byKey(const Key('goods-price-history-table')),
      );
      expect(cleared.filters['sourceNo'], isNull);
      expect(
        jsonDecode(repository.tableQueries.last['filters'] as String),
        isEmpty,
      );
    },
  );

  testWidgets(
    'shared classification and inline units persist at 1.8x mobile text',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester, _Repository(), size: const Size(375, 844));
      await tester.pumpAndSettle();
      expect(find.byType(UtenSegmentedFilter<String>), findsOneWidget);
      expect(find.textContaining('≈12.3457 人民币 / 个'), findsWidgets);
      expect(tester.takeException(), isNull);
      await scrollToRows(tester);
      final table = tester.widget<MasterDataTableView<PriceObservation>>(
        find.byKey(const Key('goods-price-history-table')),
      );
      expect(
        table.columns.any(
          (c) => c.key == 'unitName' || c.key == 'currencyName',
        ),
        isFalse,
      );
      expect(
        table.columns
            .where((c) => c.key == 'amount' || c.key == 'quantity')
            .every((c) => c.exactValueOf != null),
        isTrue,
      );
    },
  );

  testWidgets(
    'subcontract loss is lazy, grouped by plan, and revalidated before detail',
    (tester) async {
      final group = <String, dynamic>{
        'key': 'group-a',
        'supplierId': 'supplier',
        'supplierName': '委外甲',
        'unitName': '个',
        'unitRate': '1',
        'materialBasisKey': 'plan-a',
        'materialKindCount': 1,
        'sourceOrderCount': 1,
        'settledSourceOrderCount': 1,
        'settledLineCount': 1,
        'pendingLineCount': 0,
        'excludedLineCount': 0,
        'settledOrderQty': '100',
        'settledConfirmedLossQty': '0.000000000000001',
        'confirmedLossRatePct': '0.000000000000001',
        'lines': [
          {
            'orderId': 'order',
            'orderItemId': 'item',
            'orderNo': 'WW-001',
            'sourceRevision': 'v1',
            'status': 'SETTLED',
            'orderedQty': '100',
            'qualifiedStockedNetQty': '99.999999999999999',
            'confirmedLossQty': '0.000000000000001',
            'canOpenSource': false,
          },
        ],
      };
      final repository = _Repository()
        ..supplierApplicable = true
        ..supplierResponse = {
          'goodsId': 'a',
          'applicable': true,
          'dataComplete': true,
          'status': 'READY',
          'summary': '按订货日期、冻结用料方案分别统计',
          'groups': [
            group,
            {...group, 'key': 'group-b', 'materialBasisKey': 'plan-b'},
          ],
        };
      await pump(tester, repository);
      await tester.pumpAndSettle();
      await tester.tap(find.text('委外加工费'));
      await tester.pumpAndSettle();
      expect(repository.supplierQueries, isEmpty);
      await tester.tap(find.text('委外商损耗'));
      await tester.pumpAndSettle();
      expect(repository.supplierQueries, hasLength(1));
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byKey(const Key('subcontract-supplier-table')),
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'settledSourceOrderCount')
            .type,
        'number',
      );
      expect(
        table.columns.singleWhere((c) => c.key == 'supplierName').aiSensitive,
        isTrue,
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'features')
            .value(table.items[0]),
        contains('方案 1'),
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'features')
            .value(table.items[1]),
        contains('方案 2'),
      );
      expect(find.textContaining('≈1e-15%'), findsWidgets);
      await _capture(tester, 'price-supplier-loss');
      table.onRowTap!(table.items.first);
      await tester.pumpAndSettle();
      expect(repository.supplierQueries, hasLength(2));
      expect(repository.supplierQueries.last['supplierId'], 'supplier');
      expect(find.byType(GoodsSubcontractSupplierDetail), findsOneWidget);
      expect(find.text('WW-001'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GoodsSubcontractSupplierDetail),
          matching: find.text('100 个'),
        ),
        findsOneWidget,
      );
      await _capture(tester, 'price-supplier-detail');
    },
  );

  testWidgets('non subcontract goods never expose loss classification', (
    tester,
  ) async {
    final repository = _Repository();
    await pump(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('委外加工费'));
    await tester.pumpAndSettle();
    expect(find.text('委外商损耗'), findsNothing);
    expect(repository.supplierQueries, isEmpty);
  });

  testWidgets(
    'changed supplier evidence is not presented as verified history',
    (tester) async {
      final group = <String, dynamic>{
        'key': 'group',
        'supplierId': 's',
        'supplierName': '委外甲',
        'unitName': '个',
        'unitRate': '1',
        'materialBasisKey': 'one',
        'materialKindCount': 1,
        'lines': [
          {'orderId': 'o', 'orderItemId': 'i', 'sourceRevision': 'old'},
        ],
      };
      final repository = _Repository()
        ..supplierApplicable = true
        ..supplierResponse = {
          'goodsId': 'a',
          'applicable': true,
          'dataComplete': true,
          'status': 'READY',
          'groups': [group],
        };
      await pump(tester, repository);
      await tester.pumpAndSettle();
      await tester.tap(find.text('委外加工费'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('委外商损耗'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byKey(const Key('subcontract-supplier-table')),
      );
      repository.supplierResponse = {
        ...repository.supplierResponse,
        'groups': [
          {
            ...group,
            'lines': [
              {'orderId': 'o', 'orderItemId': 'i', 'sourceRevision': 'new'},
            ],
          },
        ],
      };
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(find.text('委外统计已变化，请重新加载后查看。'), findsOneWidget);
    },
  );

  for (final revoke in [false, true]) {
    testWidgets(
      'pending supplier detail cannot reappear after close or revoke ($revoke)',
      (tester) async {
        final group = <String, dynamic>{
          'key': 'group',
          'supplierId': 'supplier',
          'supplierName': '委外甲',
          'unitName': '个',
          'unitRate': '1',
          'materialBasisKey': 'one',
          'materialKindCount': 1,
          'lines': [
            {
              'orderId': 'order',
              'orderItemId': 'item',
              'sourceRevision': 'v1',
              'orderNo': 'WW-PRIVATE',
            },
          ],
        };
        final repository = _Repository()
          ..supplierApplicable = true
          ..delaySupplierDetail = true
          ..supplierResponse = {
            'goodsId': 'a',
            'applicable': true,
            'dataComplete': true,
            'status': 'READY',
            'groups': [group],
          };
        final (container, _) = await pump(tester, repository);
        await tester.pumpAndSettle();
        await tester.tap(find.text('委外加工费'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('委外商损耗'));
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          find.byKey(const Key('subcontract-supplier-table')),
        );
        table.onRowTap!(table.items.single);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(UtenBusyOverlay), findsOneWidget);
        expect(find.text('WW-PRIVATE'), findsNothing);
        if (revoke) {
          container.read(_grants.notifier).state = {Perm.goodsView};
          await tester.pumpAndSettle();
          await tester.tap(find.text('关闭'));
        } else {
          Navigator.of(
            tester.element(find.byType(GoodsSubcontractSupplierDetail)),
          ).pop();
        }
        await tester.pumpAndSettle();
        repository.pendingSupplierDetails.single.complete(
          repository.supplierResponse,
        );
        await tester.pumpAndSettle();
        expect(find.text('WW-PRIVATE'), findsNothing);
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('full history uses server pagination filters and sorting', (
    tester,
  ) async {
    final repository = _Repository();
    await pump(tester, repository);
    await tester.pumpAndSettle();
    await scrollToRows(tester);
    await tester.ensureVisible(find.text('查看全部历史'));
    await tester.tap(find.text('查看全部历史'));
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<PriceObservation>>(
      find.byKey(const Key('goods-price-history-table')),
    );
    expect(repository.tableQueries.first['page'], 1);
    expect(table.totalPages, 2);
    table.onPageChange!(2);
    await tester.pumpAndSettle();
    expect(repository.tableQueries.last['page'], 2);
    final updated = tester.widget<MasterDataTableView<PriceObservation>>(
      find.byKey(const Key('goods-price-history-table')),
    );
    updated.onFilterChanged('amount', '__null__');
    await tester.pumpAndSettle();
    expect(repository.tableQueries.last['page'], 1);
    expect(jsonDecode(repository.tableQueries.last['filters'] as String), {
      'amount': '__null__',
    });
    final filtered = tester.widget<MasterDataTableView<PriceObservation>>(
      find.byKey(const Key('goods-price-history-table')),
    );
    filtered.onSortChange!('unitPrice', false);
    await tester.pumpAndSettle();
    expect(repository.tableQueries.last['sort'], 'unitPrice');
  });

  Future<void> revealPricePanel(
    WidgetTester tester,
    Finder target, {
    BuildContext? scrollOrigin,
  }) async {
    if (target.evaluate().isEmpty) {
      final outerState = scrollOrigin == null
          ? tester.state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(UtenCollapsingHeaderScrollView),
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is Scrollable &&
                          w.axisDirection == AxisDirection.down,
                    ),
                  )
                  .first,
            )
          : Scrollable.of(scrollOrigin);
      // Resolve the dialog's actual outer viewport once. Sliver onstage
      // traversal changes as a long header leaves the viewport.
      final outerScroll = find.byElementPredicate(
        (element) => identical(element, outerState.context),
        skipOffstage: false,
      );
      for (
        var attempt = 0;
        attempt < 120 && target.evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(outerScroll, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
    }
    expect(target, findsOneWidget);
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
  }

  void expectVisiblePriceTarget(
    WidgetTester tester,
    Finder target,
    Size viewport,
  ) {
    final rect = tester.getRect(target);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(viewport.width));
    expect(rect.bottom, lessThanOrEqualTo(viewport.height));
    expect(target.hitTestable(), findsOneWidget);
  }

  Offset visiblePriceCellPoint(
    WidgetTester tester,
    Finder target,
    Size viewport,
  ) {
    final rect = tester.getRect(target);
    var visible = rect.intersect(Offset.zero & viewport);
    tester.element(target).visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final box = element.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          visible = visible.intersect(
            MatrixUtils.transformRect(
              box.getTransformTo(null),
              Offset.zero & box.size,
            ),
          );
        }
      }
      return true;
    });
    expect(visible.width, greaterThan(0));
    expect(visible.height, greaterThan(0));
    final point = visible.center;
    final localAlignment = Alignment(
      2 * (point.dx - rect.left) / rect.width - 1,
      2 * (point.dy - rect.top) / rect.height - 1,
    );
    expect(target.hitTestable(at: localAlignment), findsOneWidget);
    return point;
  }

  Widget panelHost(Widget panel, ValueChanged<Object?> returned) => Scaffold(
    body: Builder(
      builder: (context) => FilledButton(
        onPressed: () async {
          returned(
            await showDialog<Object>(
              context: context,
              builder: (_) => UtenDialogFrame(child: panel),
            ),
          );
        },
        child: const Text('open-price-panel'),
      ),
    ),
  );

  for (final size in [const Size(320, 800), const Size(640, 320)]) {
    testWidgets(
      'price panel pressure: facet field/search/selection stay exact at $size',
      (tester) async {
        final repository = _Repository();
        Object? returned;
        await pump(
          tester,
          repository,
          size: size,
          factor: 2,
          scaler: const TextScaler.linear(2),
          child: panelHost(
            const GoodsPriceFacetPicker(
              goodsId: 'a',
              query: {'kind': 'PURCHASE'},
            ),
            (value) => returned = value,
          ),
        );
        await tester.tap(find.text('open-price-panel'));
        await tester.pumpAndSettle();
        final field = find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '项目',
        );
        await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
        await tester.pumpAndSettle();
        expectVisiblePriceTarget(tester, field, size);
        final openOptions = find.descendant(
          of: field,
          matching: find.byIcon(Icons.arrow_drop_down_rounded),
        );
        expect(openOptions, findsOneWidget);
        await tester.tap(openOptions);
        await tester.pumpAndSettle();
        final menuSearch = find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.key == const Key('uten-dropdown-search-input'),
        );
        expect(menuSearch, findsOneWidget);
        await tester.enterText(menuSearch, '往来单位');
        await tester.pumpAndSettle();
        final menuList = find.descendant(
          of: find
              .ancestor(of: menuSearch, matching: find.byType(Material))
              .first,
          matching: find.byType(ListView),
        );
        expect(menuList, findsOneWidget);
        final menuScroll = find.descendant(
          of: menuList,
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        );
        expect(menuScroll, findsOneWidget);
        final option = find.descendant(
          of: menuList,
          matching: find.byWidgetPredicate(
            (w) => w is Text && w.data == '往来单位',
          ),
        );
        await tester.scrollUntilVisible(option, 80, scrollable: menuScroll);
        await Scrollable.ensureVisible(tester.element(option), alignment: 0.5);
        await tester.pumpAndSettle();
        expect(
          (Offset.zero & size).contains(tester.getRect(option).center),
          isTrue,
        );
        expect(option.hitTestable(), findsOneWidget);
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(repository.facetQueries.last['column'], 'partnerName');
        expect(
          tester.widget<UtenDropdownField>(field).selectedMaxLines,
          isNull,
        );
        final chosen = find.descendant(of: field, matching: find.text('往来单位'));
        expect(tester.widget<Text>(chosen).maxLines, isNull);
        await _capture(
          tester,
          'price-facet-selection-${size.width.toInt()}-${size.height.toInt()}',
        );
        final search = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == '搜索全部可见取值',
        );
        await Scrollable.ensureVisible(tester.element(search), alignment: 0.5);
        await tester.pumpAndSettle();
        expectVisiblePriceTarget(tester, search, size);
        await tester.enterText(search, '201');
        await tester.pump(const Duration(milliseconds: 301));
        await tester.pumpAndSettle();
        expect(repository.facetQueries.last, containsPair('search', '201'));
        expect(
          repository.facetQueries.last,
          containsPair('column', 'partnerName'),
        );
        final bucket = find.text('第201条单据');
        await revealPricePanel(tester, bucket);
        expect(
          tester
              .widget<MasterDataTableView<MasterFacetBucket>>(
                find.byType(MasterDataTableView<MasterFacetBucket>),
              )
              .primary,
          isTrue,
        );
        // A table column retains its natural width and scrolls horizontally.
        // Select the visible part of this exact server-backed bucket cell.
        final bucketPoint = visiblePriceCellPoint(tester, bucket, size);
        await _capture(
          tester,
          'price-facet-pressure-${size.width.toInt()}-${size.height.toInt()}',
        );
        await tester.tapAt(bucketPoint);
        await tester.pumpAndSettle();
        expect(returned, isA<(String, MasterFacetBucket)>());
        final selection = returned! as (String, MasterFacetBucket);
        expect(selection.$1, 'partnerName');
        expect(selection.$2.value, 'PO-201');
        expect(selection.$2.count, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'price panel pressure: detail long evidence preserves exact amounts/source at $size',
      (tester) async {
        final row = PriceObservation({
          ...observation('one'),
          'canOpenSource': true,
          'sourceRevision': 'r1',
        });
        final repository = _Repository()..delayDetail = true;
        Object? returned;
        await pump(
          tester,
          repository,
          size: size,
          factor: 2,
          scaler: const TextScaler.linear(2),
          permissions: {
            Perm.goodsView,
            Perm.goodsPriceAnalysisView,
            Perm.purchaseOrderView,
          },
          child: panelHost(
            GoodsPriceObservationDetail(
              goodsId: 'a',
              kind: 'PURCHASE',
              row: row,
              onReloadHistory: () {},
            ),
            (value) => returned = value,
          ),
        );
        await tester.tap(find.text('open-price-panel'));
        await tester.pump();
        await tester.pump();
        final summary = List.filled(30, '已核对长说明及原币金额，不改变价格、数量和币种。').join();
        repository.pendingDetails.single.complete(
          PriceObservationDetail({
            ...verifiedDetail(row).data,
            'title': '完整原始价格记录与来源版本详情',
            'summary': summary,
            'reasonCodes': [
              'NO_FINAL_INVOICE',
              'MIXED_TAX_BASIS',
              'FINAL_INVOICE_ONLY',
            ],
          }),
        );
        await tester.pumpAndSettle();
        expect(find.text(summary), findsOneWidget);
        await _capture(
          tester,
          'price-detail-evidence-${size.width.toInt()}-${size.height.toInt()}',
        );
        final tableFinder = find.byType(
          MasterDataTableView<Map<String, dynamic>>,
        );
        await revealPricePanel(
          tester,
          tableFinder,
          scrollOrigin: tester.element(find.text(summary)),
        );
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          tableFinder,
        );
        expect(table.primary, isTrue);
        expect(
          table.items.singleWhere(
            (item) => item['key'] == 'unitPrice',
          )['value'],
          '12.345678912345 人民币/个',
        );
        expect(
          table.items.singleWhere((item) => item['key'] == 'amount')['value'],
          '1234.5678912345 人民币',
        );
        final source = find.text('查看原单', skipOffstage: false);
        await revealPricePanel(tester, source);
        expectVisiblePriceTarget(tester, source, size);
        await _capture(
          tester,
          'price-detail-source-${size.width.toInt()}-${size.height.toInt()}',
        );
        await tester.tap(source);
        await tester.pumpAndSettle();
        expect(returned, isA<PriceObservation>());
        expect((returned! as PriceObservation).identity, row.identity);
        expect((returned! as PriceObservation).text('sourceRevision'), 'r1');
        expect(repository.detailQueries, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'price panel pressure: supplier long basis/source and exact ratio remain available',
    (tester) async {
      final group = <String, dynamic>{
        'key': 'group-long',
        'supplierId': 'supplier',
        'supplierName': '长名称委外加工供应商与材料计划',
        'unitName': '个',
        'unitRate': '1',
        'materialBasisKey': 'one',
        'materialKindCount': 1,
        'confirmedLossRatePct': '0.000000000000001',
        'settledOrderQty': '100.000000000000001',
        'lines': [
          {
            'orderId': 'order',
            'orderItemId': 'item',
            'sourceRevision': 'r1',
            'orderNo': 'WW-LONG',
            'canOpenSource': true,
            'orderedQty': '100.000000000000001',
            'confirmedLossQty': '0.000000000000001',
            'status': 'APPROVED',
          },
        ],
      };
      final summary = List.filled(30, '以完整订货日期和冻结用料方案核对损耗与净入库数量。').join();
      final repository = _Repository()
        ..supplierApplicable = true
        ..supplierResponse = {
          'goodsId': 'a',
          'applicable': true,
          'dataComplete': true,
          'status': 'READY',
          'summary': summary,
          'groups': [group],
        };
      Object? returned;
      await pump(
        tester,
        repository,
        size: const Size(320, 800),
        factor: 2,
        scaler: const TextScaler.linear(2),
        permissions: {
          Perm.goodsView,
          Perm.goodsPriceAnalysisView,
          Perm.subcontractOrderView,
        },
        child: panelHost(
          GoodsSubcontractSupplierDetail(
            goodsId: 'a',
            days: 90,
            group: {...group, '_planLabel': '方案 1'},
            onRefresh: () {},
          ),
          (value) => returned = value,
        ),
      );
      await tester.tap(find.text('open-price-panel'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('损耗统计依据')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      expectVisiblePriceTarget(
        tester,
        find.text('损耗统计依据'),
        const Size(320, 800),
      );
      await tester.tap(find.text('损耗统计依据'));
      await tester.pumpAndSettle();
      expect(find.text(summary), findsOneWidget);
      await _capture(tester, 'price-supplier-expanded-basis-320-800');
      final tableFinder = find.byType(
        MasterDataTableView<Map<String, dynamic>>,
      );
      await revealPricePanel(tester, tableFinder);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        tableFinder,
      );
      expect(table.primary, isTrue);
      expect(
        table.columns.singleWhere((c) => c.key == 'orderedQty').exactValueOf!(
          table.items.single,
        ),
        '100.000000000000001',
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'confirmedLossQty')
            .exactValueOf!(table.items.single),
        '0.000000000000001',
      );
      final source = find.widgetWithText(TextButton, '查看原单');
      await revealPricePanel(tester, source);
      expectVisiblePriceTarget(tester, source, const Size(320, 800));
      await _capture(tester, 'price-supplier-source-320-800');
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(returned, 'order');
      expect(repository.supplierQueries.single['supplierId'], 'supplier');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'price panel pressure: supplier wheel collapses the sole page header before rows',
    (tester) async {
      final groups = [
        for (var i = 0; i < 25; i++)
          <String, dynamic>{
            'key': 'group-$i',
            'supplierId': 'supplier-$i',
            'supplierName': '委外商$i',
            'materialBasisKey': 'basis-$i',
            'materialKindCount': 1,
            'unitRate': '1',
            'unitName': '个',
            'confirmedLossRatePct': '0.000000000000001',
            'settledOrderQty': '100.000000000000001',
            'lines': [
              {
                'orderId': 'order-$i',
                'orderItemId': 'item-$i',
                'sourceRevision': 'r1',
              },
            ],
          },
      ];
      final repository = _Repository()
        ..supplierApplicable = true
        ..supplierResponse = {
          'goodsId': 'a',
          'applicable': true,
          'dataComplete': true,
          'status': 'READY',
          'groups': groups,
        };
      await pump(tester, repository);
      await tester.pumpAndSettle();
      await tester.tap(find.text('委外加工费'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('委外商损耗'));
      await tester.pumpAndSettle();
      expect(
        find.byType(UtenCollapsingHeaderScrollView),
        findsOneWidget,
        reason: '嵌入供应商表复用主页面联动，不能再注册第二个wheel gate',
      );
      final control = find.byKey(const ValueKey('price-analysis-days'));
      final before = tester.getTopLeft(control).dy;
      final tableFinder = find.byKey(const Key('subcontract-supplier-table'));
      final point = tester.getRect(tableFinder).center;
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 180)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(control).dy,
        lessThan(before),
        reason: '真实table上的wheel先收起同一主页面控制区',
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        tableFinder,
      );
      expect(table.primary, isTrue);
      expect(
        table.columns
            .singleWhere((c) => c.key == 'confirmedLossRatePct')
            .exactValueOf!(table.items.first),
        '0.000000000000001',
      );
      final row = find.byKey(const ValueKey('supplier-group-group-0'));
      await Scrollable.ensureVisible(tester.element(row), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getRect(row).center);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(tester.getRect(row).center);
      await tester.pumpAndSettle();
      expect(find.byType(GoodsSubcontractSupplierDetail), findsOneWidget);
      expect(repository.supplierQueries.last['supplierId'], 'supplier-0');
      expect(tester.takeException(), isNull);
    },
  );
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
