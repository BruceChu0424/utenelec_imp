// 车间内料仓用量报表与结算页 (ADR-131 §5.10)：
//  1. 没有看成本权限的人 (服务端金额下发为空) 看不到金额列，有金额时出现；
//  2. 产品用料：独占期平均耗用与分摊区分，估盘来源沿期初/期末展示；
//  3. 结算被拦：三种拦截文案与负责人都显示；按钮只按服务端 allowedActions 出现；
//  4. 撤销结算：先填原因，服务端要求再认证时弹统一密码框，输完后撤销生效；
//     版本取结算状态里的最新期间版本 (每次结算尝试都会让它 +1)，不用期间列表里的旧值；
//  5. 服务端报表行形状：收发明细「来源单据」= 库存单据号 / 领料单号，盘点过账显示「盘点」。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/step_up_coordinator.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/workshop_material_report_models.dart';
import 'package:uten_imp/features/production/pages/workshop_material_reports_page.dart';
import 'package:uten_imp/features/production/repositories/workshop_material_report_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';
import '../../support/filter_segment_tap.dart';
import '../../support/audit_screenshot_support.dart';

class _WasteNonlinearScaler extends TextScaler {
  const _WasteNonlinearScaler();
  @override
  double scale(double fontSize) => fontSize <= 1
      ? fontSize
      : fontSize <= 20
      ? fontSize * 2
      : fontSize * 1.4;
  @override
  double get textScaleFactor => 2;
}

class _FakeRepo implements WorkshopMaterialReportRepository {
  _FakeRepo({
    this.usage = const [],
    this.product = const [],
    this.trend = const [],
    Map<String, WmReportCloseStatus>? statuses,
  }) : statuses = statuses ?? {};

  final List<WmBinUsageRow> usage;
  final List<WmProductUsageRow> product;
  final List<WmWasteTrendPoint> trend;
  final trendReads = <String>[];
  final Map<String, WmReportCloseStatus> statuses;
  final reopenCalls = <({String periodId, int? version, String reason})>[];
  final stepUpTokens = <String?>[];

  @override
  Future<List<WmReportBin>> bins() async => const [
    WmReportBin(
      binWarehouseId: 'bin-1',
      workshopDepartmentId: 'ws-1',
      workshopName: '注塑车间',
      binWarehouseName: '注塑车间内料仓',
      periodicEnabled: true,
    ),
  ];

  @override
  Future<List<WmReportPeriod>> periods(String binId) async => const [
    WmReportPeriod(
      id: 'p1',
      periodNo: 1,
      startDate: '2026-09-01',
      endDate: '2026-09-15',
      status: 'CLOSED',
      closeState: 'NONE',
      rowVersion: 7,
    ),
    WmReportPeriod(
      id: 'p2',
      periodNo: 2,
      startDate: '2026-09-16',
      endDate: '2026-09-27',
      status: 'COUNTED',
      closeState: 'BLOCKED',
      rowVersion: 3,
    ),
    WmReportPeriod(
      id: 'p3',
      periodNo: 3,
      startDate: '2026-09-28',
      status: 'OPEN',
      closeState: 'NONE',
      rowVersion: 0,
    ),
  ];

  @override
  Future<WmReportCloseStatus> closeStatus(String periodId) async =>
      statuses[periodId] ??
      WmReportCloseStatus(periodId: periodId, status: 'OPEN');

  @override
  Future<WmReportCloseStatus> retryClose(WmReportCloseStatus current) async =>
      throw UnimplementedError();

  @override
  Future<WmReportCloseStatus> reopen(
    String periodId, {
    required int? expectedVersion,
    required String reason,
  }) async {
    // 模拟服务端 @RequiresStepUp：网络层向协调器要一张再认证凭证。
    stepUpTokens.add(await StepUpCoordinator.instance.obtain());
    reopenCalls.add((
      periodId: periodId,
      version: expectedVersion,
      reason: reason,
    ));
    final held = WmReportCloseStatus(
      periodId: periodId,
      status: 'COUNTED',
      closeState: 'HELD',
      heldUntil: '2026-09-29T10:00:00+08:00',
      allowedActions: const {'CLOSE_RETRY'},
    );
    statuses[periodId] = held;
    return held;
  }

  @override
  Future<List<WmBinUsageRow>> binUsage(
    String binId, {
    String? from,
    String? to,
  }) async => usage;

  @override
  Future<List<WmProductUsageRow>> productUsage(
    String binId, {
    String? from,
    String? to,
  }) async => product;

  @override
  Future<List<WmWasteTrendPoint>> wasteTrend(
    String binId, {
    String? goodsId,
  }) async {
    trendReads.add(binId);
    return trend;
  }

  @override
  Future<List<WmMissingWeightRow>> missingWeights(String binId) async =>
      const [];

  @override
  Future<PagedResult<WmLedgerRow>> ledger(
    String binId, {
    String? from,
    String? to,
    int page = 1,
    int size = 50,
  }) async =>
      const PagedResult(items: [], page: 1, size: 50, total: 0, totalPages: 1);
}

class _OpenedOnlyRepo extends _FakeRepo {
  final periodReads = <String>[];

  @override
  Future<List<WmReportBin>> bins() async => [
    WmReportBin.fromSettingsJson({
      'workshopDepartmentId': 'ws-1',
      'workshopName': '注塑车间',
      'status': 'OPEN',
      'binOpened': true,
      'periodicEnabled': false,
      'binWarehouseId': 'bin-opened',
      'binWarehouseName': '注塑车间内料仓',
    })!,
  ];

  @override
  Future<List<WmReportPeriod>> periods(String binId) async {
    periodReads.add(binId);
    return const [];
  }
}

const _usageRow = WmBinUsageRow(
  periodId: 'p1',
  periodNo: 1,
  startDate: '2026-09-01',
  endDate: '2026-09-15',
  goodsId: 'pc',
  goodsName: 'PC E-15',
  costBasis: 'OWN',
  openingQty: 0,
  transferInQty: 100,
  returnQty: 0,
  otherIssueQty: 2,
  closingQty: 18,
  actualQty: 80,
  theoryQty: 75,
  diffQty: 5,
  wasteRate: 0.0667,
  outcome: 'ALLOCATED',
  consumedQty: 80,
);

WmBinUsageRow _withCost(WmBinUsageRow r) => WmBinUsageRow(
  periodId: r.periodId,
  periodNo: r.periodNo,
  startDate: r.startDate,
  endDate: r.endDate,
  goodsId: r.goodsId,
  goodsName: r.goodsName,
  costBasis: r.costBasis,
  actualQty: r.actualQty,
  theoryQty: r.theoryQty,
  wasteRate: r.wasteRate,
  outcome: r.outcome,
  unitCost: 12.5,
  currentValue: 1000,
  valueAtClose: 1000,
);

Future<void> _pump(
  WidgetTester tester,
  _FakeRepo repo, {
  String? initialPeriodId,
  GlobalKey<NavigatorState>? navigatorKey,
  Size size = const Size(1600, 1000),
  double factor = 1,
  TextScaler? scaler,
  ThemeData? theme,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      // 每个伪仓库一棵新树：同一个测试里换数据重新进页面。
      key: ValueKey(repo),
      overrides: [
        workshopMaterialReportRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: theme,
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
        locale: const Locale('zh'),
        home: WorkshopMaterialReportsPage(initialPeriodId: initialPeriodId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  _serverShapeTests();

  testWidgets('已开通但未整批领料的内料仓可浏览空报表且不显示蓝色说明', (tester) async {
    final repo = _OpenedOnlyRepo();
    await _pump(tester, repo);
    expect(find.text('注塑车间内料仓'), findsOneWidget);
    expect(repo.periodReads, ['bin-opened']);
    expect(find.text('这个仓库不是车间内料仓'), findsNothing);
    expect(find.textContaining('耗用由期初和期末盘点推算'), findsNothing);
    await selectFilterSegment(tester, '产品用料');
    await tester.pumpAndSettle();
    expect(find.textContaining('耗用由期初和期末盘点推算'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    '320 2x nonlinear waste trend keeps axes, extreme/null facts and selection',
    (tester) async {
      await loadAuditScreenshotFonts(tester);
      const scaler = _WasteNonlinearScaler();
      const points = [
        WmWasteTrendPoint(
          periodId: 'trend-1',
          periodNo: 1,
          startDate: '2026-09-01',
          endDate: '2026-09-15',
          goodsId: 'pc',
          goodsName: 'PC E-15',
          colorId: 'gray',
          colorName: '灰',
          wasteRate: -.3,
          openingCountBasis: 'ESTIMATED',
          closingCountBasis: 'WEIGHED',
        ),
        WmWasteTrendPoint(
          periodId: 'trend-2',
          periodNo: 2,
          startDate: '2026-09-16',
          endDate: '2026-09-16',
          goodsId: 'pc',
          goodsName: 'PC E-15',
          colorId: 'gray',
          colorName: '灰',
        ),
        WmWasteTrendPoint(
          periodId: 'trend-3',
          periodNo: 3,
          startDate: '2026-09-17',
          endDate: '2026-09-17',
          goodsId: 'pc',
          goodsName: 'PC E-15',
          colorId: 'gray',
          colorName: '灰',
          wasteRate: .5,
          openingCountBasis: 'WEIGHED',
          closingCountBasis: 'WEIGHED',
        ),
        WmWasteTrendPoint(
          periodId: 'trend-4',
          periodNo: 4,
          startDate: '2026-09-18',
          endDate: '2026-09-18',
          goodsId: 'pc',
          goodsName: 'PC E-15',
          colorId: 'gray',
          colorName: '灰',
          wasteRate: 1000000,
          openingCountBasis: 'WEIGHED',
          closingCountBasis: 'WEIGHED',
        ),
        WmWasteTrendPoint(
          periodId: 'single-null',
          periodNo: 5,
          startDate: '2026-09-19',
          endDate: '2026-09-19',
          goodsId: 'single',
          goodsName: '单点材料',
          colorId: 'clear',
          colorName: '透明',
        ),
      ];
      final repo = _FakeRepo(trend: points, usage: const [_usageRow]);
      final theme = auditScreenshotTheme(buildLightTheme());
      await _pump(
        tester,
        repo,
        size: const Size(320, 640),
        factor: 2,
        scaler: scaler,
        theme: theme,
      );
      final page = find.byType(WorkshopMaterialReportsPage);
      final pageState = tester.state(page);
      final binState = tester.state(find.byKey(const Key('wm-report-bin')));
      Future<void> revealThroughOuter(
        Finder target, {
        bool towardHeader = false,
      }) async {
        final outer = find
            .descendant(
              of: find.byKey(const Key('wm-report-coordinator')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first;
        for (var i = 0; i < 40 && !tester.any(target); i++) {
          final window =
              Offset.zero &
              (tester.view.physicalSize / tester.view.devicePixelRatio);
          final visible = tester.getRect(outer).intersect(window);
          expect(visible.isEmpty, isFalse);
          final pointer = Offset(
            visible.left + visible.width / 4,
            visible.center.dy,
          );
          if (towardHeader) {
            // At the table, a downward touch drag can belong to the inner
            // viewport. Use the real wheel handoff to return to the outer
            // header before asking ensureVisible to reveal its lazy segment.
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: pointer,
                scrollDelta: const Offset(0, -240),
              ),
            );
          } else {
            await tester.dragFrom(pointer, const Offset(0, -240));
          }
          await tester.pumpAndSettle();
        }
        expect(
          target,
          findsOneWidget,
          reason:
              'real vertical scrolling must materialize the lazy report content',
        );
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
      }

      expect(
        tester.takeException(),
        isNull,
        reason:
            'initial usage notice must scroll in the common header instead of squeezing the table',
      );
      final initialTableFinder = find.byKey(
        const ValueKey('wm-usage-table-false'),
      );
      await revealThroughOuter(initialTableFinder);
      final initialTable = tester.widget<MasterDataTableView<WmBinUsageRow>>(
        initialTableFinder,
      );
      expect(initialTable.items.single.actualQty, 80);
      expect(initialTable.items.single.periodId, 'p1');
      final view = find.byKey(const Key('wm-report-view-segments'));
      await revealThroughOuter(view, towardHeader: true);
      final viewToggle = find.descendant(
        of: view,
        matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
      );
      if (tester.any(viewToggle)) {
        await tester.ensureVisible(viewToggle);
        await tester.pumpAndSettle();
        expect(viewToggle.hitTestable(), findsOneWidget);
      }
      await selectFilterSegment(
        tester,
        AppLocalizations.of(tester.element(page)).wmReportTrend,
      );
      await tester.pumpAndSettle();
      expect(repo.trendReads, ['bin-1']);
      final body = find.byKey(const Key('wm-trend-scroll'));
      await revealThroughOuter(body);
      final chart = find.byKey(const Key('wm-trend-chart-canvas'));
      await revealThroughOuter(chart);
      final vertical = find
          .descendant(
            of: body,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      await tester.scrollUntilVisible(chart, 80, scrollable: vertical);
      await tester.pumpAndSettle();
      final painter =
          tester.widget<CustomPaint>(chart).painter! as WasteTrendPainter;
      expect(painter.textScaler, same(scaler));
      expect(scaler.scale(1), 1);
      expect(painter.range, (-40.0, 100000010.0));
      expect(painter.points.map((point) => point.periodId), [
        'trend-1',
        'trend-2',
        'trend-3',
        'trend-4',
      ]);
      expect(painter.points.map((point) => point.wasteRate), [
        -.3,
        null,
        .5,
        1000000,
      ]);
      final chartSize = tester.getSize(chart);
      expect(
        chartSize.height,
        lessThan(500),
        reason: 'an extreme rate cannot create an enormous surface',
      );
      final labels = painter.labelBounds(chartSize);
      final ticks = labels.where((label) => !label.date).toList();
      final dates = labels.where((label) => label.date).toList();
      expect(ticks.map((label) => label.text), ['-30%', '0%', '50%']);
      expect(dates.first.text, '09-15');
      expect(dates.last.text, '09-18');
      for (final label in labels) {
        final bounds = label.bounds;
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(chartSize.width));
        expect(bounds.bottom, lessThanOrEqualTo(chartSize.height));
      }
      for (var i = 1; i < dates.length; i++) {
        expect(
          dates[i - 1].bounds.right,
          lessThanOrEqualTo(dates[i].bounds.left),
        );
      }
      for (var i = 0; i < ticks.length; i++) {
        for (var j = i + 1; j < ticks.length; j++) {
          expect(ticks[i].bounds.overlaps(ticks[j].bounds), isFalse);
        }
      }
      final render = tester.renderObject(chart);
      expect(render, paintsExactlyCountTimes(#drawCircle, 3));
      expect(
        render,
        paints
          ..circle(
            radius: 3.5,
            color: painter.lineColor,
            style: PaintingStyle.stroke,
          )
          ..circle(
            radius: 3.5,
            color: painter.lineColor,
            style: PaintingStyle.fill,
          )
          ..circle(
            radius: 5,
            color: painter.alertColor,
            style: PaintingStyle.fill,
          ),
      );
      final horizontal = find.descendant(
        of: find.byKey(const Key('wm-trend-chart')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.right,
        ),
      );
      final horizontalState = tester.state<ScrollableState>(horizontal);
      expect(horizontalState.position.maxScrollExtent, greaterThan(0));
      final window =
          Offset.zero &
          (tester.view.physicalSize / tester.view.devicePixelRatio);
      final visibleChart = tester.getRect(horizontal).intersect(window);
      expect(visibleChart.isEmpty, isFalse);
      await tester.dragFrom(visibleChart.center, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(horizontalState.position.pixels, greaterThan(0));
      final outerViewport = find
          .descendant(
            of: find.byKey(const Key('wm-report-coordinator')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      Rect bodyViewport() => tester
          .getRect(vertical)
          .intersect(tester.getRect(outerViewport))
          .intersect(
            Offset.zero &
                (tester.view.physicalSize / tester.view.devicePixelRatio),
          );
      Future<void> revealBodyTarget(
        Finder target, {
        bool towardStart = false,
        bool mustHit = false,
      }) async {
        for (var i = 0; i < 160; i++) {
          if (tester.any(target) &&
              (!mustHit || tester.any(target.hitTestable()))) {
            break;
          }
          final viewport = bodyViewport();
          expect(viewport.isEmpty, isFalse);
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: viewport.center,
              scrollDelta: Offset(0, towardStart ? -240 : 240),
            ),
          );
          await tester.pumpAndSettle();
        }
        expect(
          target,
          findsOneWidget,
          reason: 'real linked scrolling must materialize the requested body',
        );
        if (mustHit) {
          expect(target.hitTestable(), findsOneWidget);
        } else {
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
        }
      }

      Future<void> expectWholeReadoutReachable(Finder target) async {
        await revealBodyTarget(target);
        final text = tester.widget<Text>(target);
        expect(text.maxLines, isNull);
        expect(text.overflow, isNull);
        final paragraphs = find.descendant(
          of: target,
          matching: find.byType(RichText),
        );
        expect(paragraphs, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(paragraphs);
        final fullText = paragraph.text.toPlainText();
        expect(fullText, text.data);
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: fullText.length),
        );
        expect(boxes, isNotEmpty);
        for (final box in boxes) {
          Rect glyphRect() => Rect.fromPoints(
            paragraph.localToGlobal(Offset(box.left, box.top)),
            paragraph.localToGlobal(Offset(box.right, box.bottom)),
          );
          bool inside(Rect glyph, Rect viewport) =>
              glyph.left >= viewport.left - 0.5 &&
              glyph.right <= viewport.right + 0.5 &&
              glyph.top >= viewport.top - 0.5 &&
              glyph.bottom <= viewport.bottom + 0.5;

          for (var i = 0; i < 40; i++) {
            final viewport = bodyViewport();
            final glyph = glyphRect();
            expect(viewport.isEmpty, isFalse);
            expect(glyph.width, lessThanOrEqualTo(viewport.width + 1));
            expect(glyph.height, lessThanOrEqualTo(viewport.height + 1));
            if (inside(glyph, viewport)) break;
            // Window deltas enter the real linked-scroll wheel handoff. Do
            // not scale again, jump the controller or bypass a lazy viewport.
            final delta = (glyph.center.dy - viewport.center.dy)
                .clamp(-240.0, 240.0)
                .toDouble();
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: viewport.center,
                scrollDelta: Offset(0, delta),
              ),
            );
            await tester.pumpAndSettle();
          }
          final glyph = glyphRect();
          expect(
            inside(glyph, bodyViewport()),
            isTrue,
            reason:
                'each complete glyph run, including the first and last, '
                'must be reachable within the real body viewport: $fullText',
          );
          expect(
            tester
                .hitTestOnBinding(glyph.center)
                .path
                .any((entry) => entry.target == paragraph),
            isTrue,
            reason: 'the visible readout must hit the original paragraph',
          );
        }
      }

      final rateLabel = AppLocalizations.of(tester.element(page)).wmWasteRate;
      final expectedRates = [
        '$rateLabel ≈ -30.0%',
        '$rateLabel ',
        '$rateLabel 50.0%',
        '$rateLabel 100000000.0%',
      ];
      final reviewedRates = <String>[];
      for (final period in [1, 2, 3, 4]) {
        final row = find.textContaining('第 $period 期');
        await expectWholeReadoutReachable(row);
        // Review the rate next to its own period before moving onward. The
        // prior captions legitimately leave the lazy viewport after scrolling.
        final caption = find
            .ancestor(of: row, matching: find.byType(Column))
            .first;
        final value = find.descendant(
          of: caption,
          matching: find.text(expectedRates[period - 1]),
        );
        expect(value, findsOneWidget);
        expect(tester.widget<Text>(value).data, expectedRates[period - 1]);
        await expectWholeReadoutReachable(value);
        reviewedRates.add(tester.widget<Text>(value).data!);
      }
      expect(reviewedRates, expectedRates);
      for (final reading in ['-30.0%', '50.0%', '100000000.0%']) {
        expect(
          reviewedRates.where((caption) => caption.endsWith(reading)),
          hasLength(1),
          reason: 'the exact rate must already have passed full glyph review',
        );
      }
      final selector = find.byKey(const Key('wm-trend-material'));
      // Returning from all long captions exceeds the stock 50 small drags.
      // Use real reverse wheel handoff until the original field is clickable.
      await revealBodyTarget(selector, towardStart: true, mustHit: true);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('单点材料 透明').last);
      await tester.pumpAndSettle();
      expect(tester.widget<UtenDropdownField>(selector).value, 'single|clear');
      await revealBodyTarget(chart);
      final nullPainter =
          tester.widget<CustomPaint>(chart).painter! as WasteTrendPainter;
      expect(nullPainter.range, (-40.0, 60.0));
      expect(nullPainter.points.single, same(points.last));
      expect(
        tester.renderObject(chart),
        paintsExactlyCountTimes(#drawCircle, 0),
      );
      expect(repo.trendReads, ['bin-1']);
      final chartState = tester.state(find.byKey(const Key('wm-trend-chart')));
      await _pump(
        tester,
        repo,
        size: const Size(1200, 900),
        scaler: scaler,
        theme: theme,
      );
      expect(tester.state(page), same(pageState));
      expect(
        tester.state(find.byKey(const Key('wm-report-bin'))),
        same(binState),
      );
      expect(
        tester.state(find.byKey(const Key('wm-trend-chart'))),
        same(chartState),
      );
      expect(tester.widget<UtenDropdownField>(selector).value, 'single|clear');
      expect(
        tester
            .widget<UtenDropdownField>(find.byKey(const Key('wm-report-bin')))
            .value,
        'bin-1',
      );
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('wm-report-period')),
            )
            .value,
        '',
      );
      expect(repo.trendReads, ['bin-1']);
      expect(repo.reopenCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('服务端没给金额 (无看成本权限) 时金额列整列隐藏，有金额时出现', (tester) async {
    await _pump(tester, _FakeRepo(usage: const [_usageRow]));

    expect(find.text('PC E-15'), findsOneWidget);
    expect(find.text('盘点推算耗用'), findsOneWidget);
    expect(find.text('金额'), findsNothing);
    expect(find.text('结算时金额'), findsNothing);
    expect(find.text('单价'), findsNothing);

    await _pump(tester, _FakeRepo(usage: [_withCost(_usageRow)]));
    expect(find.text('金额'), findsOneWidget);
    expect(find.text('结算时金额'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('产品用料：独占期平均不冒充实测，并展示期初估盘来源', (tester) async {
    await _pump(
      tester,
      _FakeRepo(
        product: const [
          WmProductUsageRow(
            periodId: 'p1',
            periodNo: 1,
            productCode: 'A01',
            productName: '外壳',
            materialName: 'PC E-15',
            outputQty: 1000,
            unitWeightGrams: 12.5,
            theoryQty: 12.5,
            allocatedQty: 13,
            exclusivePeriod: true,
            actualPerUnitGrams: 13,
            openingCountBasis: 'ESTIMATED',
            closingCountBasis: 'WEIGHED',
            materialUnitName: 'kg',
          ),
          WmProductUsageRow(
            periodId: 'p1',
            periodNo: 1,
            productCode: 'B02',
            productName: '底座',
            materialName: 'ABS 757',
            outputQty: 500,
            unitWeightGrams: 20,
            theoryQty: 10,
            allocatedQty: 11,
          ),
        ],
      ),
    );

    await tester.tap(find.text('产品用料'));
    await tester.pumpAndSettle();

    expect(find.text('独占期平均耗用'), findsOneWidget);
    expect(find.text('真实单耗'), findsNothing);
    expect(find.text('按理论比例分摊'), findsOneWidget);
    expect(find.text('12.5'), findsWidgets);
    expect(find.text('材料金额'), findsNothing, reason: '没有金额时不出金额列');
    final table = tester.widget<MasterDataTableView<WmProductUsageRow>>(
      find.byType(MasterDataTableView<WmProductUsageRow>),
    );
    final evidence = table.columns.singleWhere(
      (column) => column.key == 'countEvidence',
    );
    expect(evidence.value(table.items.first), '期初：含容器估盘；期末：称重/公斤录入');
    expect(table.columns.map((column) => column.label), contains('分摊耗用'));
    final unit = table.columns.singleWhere(
      (column) => column.key == 'materialUnit',
    );
    expect(unit.label, '材料单位');
    expect(unit.value(table.items.first), 'kg');
    expect(find.textContaining('不等于报废率'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('结算被拦：三种拦截文案与负责人都显示，按钮只按 allowedActions 出现', (tester) async {
    await _pump(
      tester,
      _FakeRepo(
        statuses: {
          'p2': const WmReportCloseStatus(
            periodId: 'p2',
            status: 'COUNTED',
            closeState: 'BLOCKED',
            blockers: [
              WmReportCloseBlocker(
                kind: 'DRAFT_REPORT',
                count: 2,
                responsible: '报工审核人或制单人',
                samples: ['RB20260920001', 'RB20260921002'],
              ),
              WmReportCloseBlocker(
                kind: 'MISSING_WEIGHT',
                count: 1,
                samples: ['外壳'],
              ),
              WmReportCloseBlocker(
                kind: 'THEORY_WITHOUT_STOCK',
                count: 1,
                samples: ['PC E-15'],
              ),
            ],
          ),
        },
      ),
    );

    // 没选期间：结算状态卡看最近一次盘点的那一期 (第 2 期)。
    expect(find.byKey(const Key('wm-close-status-card')), findsOneWidget);
    expect(find.textContaining('第 2 期'), findsWidgets);
    expect(find.textContaining('还有 2 张报工没审核'), findsOneWidget);
    expect(find.textContaining('RB20260920001'), findsOneWidget);
    expect(find.textContaining('负责：报工审核人或制单人'), findsOneWidget);
    expect(find.textContaining('有 1 个产品没填单个重量'), findsOneWidget);
    expect(find.textContaining('「PC E-15」这一期没有发料记录'), findsOneWidget);
    // 服务端没给动作：不出现重试 / 撤销按钮。
    expect(find.byKey(const Key('wm-close-retry')), findsNothing);
    expect(find.byKey(const Key('wm-close-reopen')), findsNothing);
    // 面向员工的文案不出现内部代号。
    for (final code in [
      'DRAFT_REPORT',
      'MISSING_WEIGHT',
      'BLOCKED',
      'COUNTED',
    ]) {
      expect(find.textContaining(code), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤销结算：填原因后触发再认证弹窗，输完密码撤销生效', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final verified = <String>[];
    final unregister = StepUpCoordinator.instance.register(
      () => showReauthDialog(
        navigatorKey.currentContext!,
        verify: (password) async {
          verified.add(password);
          return 'one-time-token';
        },
      ),
    );
    addTearDown(unregister);
    final repo = _FakeRepo(
      statuses: {
        'p1': const WmReportCloseStatus(
          periodId: 'p1',
          status: 'CLOSED',
          lastCloseNo: 1,
          lastClosedByName: '张三',
          rowVersion: 9,
          allowedActions: {'REOPEN'},
        ),
      },
    );
    await _pump(
      tester,
      repo,
      initialPeriodId: 'p1',
      navigatorKey: navigatorKey,
    );

    expect(find.text('已结算'), findsWidgets);
    expect(find.byKey(const Key('wm-close-retry')), findsNothing);
    await tester.tap(find.byKey(const Key('wm-close-reopen')));
    await tester.pumpAndSettle();

    // 原因必填：空着点确认不关框。
    await tester.tap(find.byKey(const Key('wm-reopen-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wm-reopen-reason')), findsOneWidget);
    expect(repo.reopenCalls, isEmpty);

    await tester.enterText(
      find.byKey(const Key('wm-reopen-reason')),
      '单个重量填错了，改完重结',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-reopen-confirm')));
    await _frames(tester);

    // 服务端要求再认证：统一密码框压在忙碌遮罩之上。
    expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-password'))),
    );
    await tester.pump();
    tester.testTextInput.enterText('CorrectPassword1');
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-confirm'))),
    );
    await _frames(tester);
    await tester.pumpAndSettle();

    expect(verified, ['CorrectPassword1']);
    expect(repo.stepUpTokens, ['one-time-token']);
    expect(repo.reopenCalls, hasLength(1));
    expect(repo.reopenCalls.single.periodId, 'p1');
    // 期间列表里是 7，结算状态里最新是 9：以 9 提交。
    expect(repo.reopenCalls.single.version, 9);
    expect(repo.reopenCalls.single.reason, '单个重量填错了，改完重结');
    // 撤销后：保留 24 小时的说明 + 「重新结算」按钮 (服务端给了 CLOSE_RETRY)。
    expect(find.byKey(const Key('wm-close-held')), findsOneWidget);
    expect(find.text('重新结算'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 服务端报表行形状 (WorkshopMaterialReportDtos / CloseStatusView)。
void _serverShapeTests() {
  test('盘点来源兼容旧响应，期初或期末估盘都影响本期而独占不改变可信度', () {
    final inherited = WmBinUsageRow.fromJson({
      'openingCountBasis': 'ESTIMATED',
      'closingCountBasis': 'WEIGHED',
      'actualQty': 90,
    });
    expect(inherited.hasEstimatedCount, isTrue);
    expect(inherited.hasUnknownCount, isFalse);
    expect(inherited.actualQty, 90);
    final product = WmProductUsageRow.fromJson({
      'exclusivePeriod': true,
      'openingCountBasis': 'BAG_COUNT',
      'closingCountBasis': 'ESTIMATED',
      'actualPerUnit': 0.013,
      'materialUnitKgFactor': 1,
    });
    expect(product.hasEstimatedCount, isTrue);
    expect(product.actualPerUnitGrams, 13);
    final old = WmBinUsageRow.fromJson({'actualQty': 90});
    expect(old.hasUnknownCount, isTrue);
    expect(old.countEvidenceLabel, '期初：来源未提供；期末：来源未提供');
    final trend = WmWasteTrendPoint.fromJson({
      'openingCountBasis': 'EMPTY_START',
      'closingCountBasis': 'WEIGHED_AND_BAGS',
    });
    expect(trend.hasEstimatedCount, isFalse);
    expect(trend.hasUnknownCount, isFalse);
  });

  test('产品用量按服务端质量单位因子换克，别名和未知单位不靠名字猜', () {
    WmProductUsageRow read(double? factor, {String name = '别名单位'}) =>
        WmProductUsageRow.fromJson({
          'unitWeight': 12.5,
          'actualPerUnit': 13,
          'materialUnitName': name,
          'materialUnitKgFactor': factor,
        });
    expect(read(0.001).unitWeightGrams, closeTo(12.5, 0.000000001));
    expect(read(0.001).actualPerUnitGrams, closeTo(13, 0.000000001));
    expect(read(1).unitWeightGrams, closeTo(12500, 0.000000001));
    expect(read(0.45359237).unitWeightGrams, closeTo(5669.904625, 0.000001));
    final unknown = read(null, name: 'kg');
    expect(unknown.unitWeightGrams, isNull);
    expect(unknown.actualPerUnitGrams, isNull);
    expect(unknown.unitWeightBase, 12.5);
    expect(unknown.materialUnitName, 'kg');
    expect(read(0).unitWeightGrams, isNull);
  });

  test('已审核期初和账面修正与领入分开保留', () {
    final row = WmBinUsageRow.fromJson({
      'openingCountBasis': 'APPROVED_OPENING',
      'closingCountBasis': 'WEIGHED',
      'transferInQty': 100,
      'adjustmentQty': -5,
    });
    expect(row.hasUnknownCount, isFalse);
    expect(row.countEvidenceLabel, '期初：已审核期初盘点；期末：称重/公斤录入');
    expect(row.transferInQty, 100);
    expect(row.adjustmentQty, -5);
    expect(WmLedgerRow.fromJson({'sourceKind': 'OPENING'}).sourceLabel, '盘点审核');
    expect(
      WmLedgerRow.fromJson({'sourceKind': 'ADJUSTMENT'}).sourceLabel,
      '盘点审核',
    );
  });

  test('收发明细：来源单据取库存单据号与领料单号，盘点过账显示盘点', () {
    final issue = WmLedgerRow.fromJson({
      'sourceRowId': 'r1',
      'sourceKind': 'ISSUE',
      'docNo': 'DB20260901001',
      'requestNo': 'LL20260901001',
      'supplement': true,
      'signedQty': 50,
    });
    expect(issue.id, 'r1');
    expect(issue.isSupplement, isTrue);
    expect(issue.sourceLabel, 'DB20260901001 / LL20260901001');
    final consume = WmLedgerRow.fromJson({
      'sourceRowId': 'r2',
      'sourceKind': 'CONSUME',
      'signedQty': -12.5,
    });
    expect(consume.sourceLabel, '盘点');
  });

  test('结算状态带期间最新版本；浪费率按货品 + 颜色 id 分组', () {
    final status = WmReportCloseStatus.fromJson({
      'periodId': 'p1',
      'status': 'CLOSED',
      'closeState': 'NONE',
      'rowVersion': 12,
      'lastClose': {'closeNo': 2, 'closedByName': '张三'},
      'allowedActions': ['REOPEN'],
    }, periodId: 'p1');
    expect(status.rowVersion, 12);
    expect(status.lastCloseNo, 2);
    final a = WmWasteTrendPoint.fromJson({
      'goodsId': 'g',
      'colorId': 'c1',
      'colorName': '黑',
    });
    final b = WmWasteTrendPoint.fromJson({
      'goodsId': 'g',
      'colorId': 'c2',
      'colorName': '黑',
    });
    expect(a.materialKey == b.materialKey, isFalse);
  });
}

/// 忙碌遮罩里的进度圈一直在转，不能 pumpAndSettle；固定推进若干帧。
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
