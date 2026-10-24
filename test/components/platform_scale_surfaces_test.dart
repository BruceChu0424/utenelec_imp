import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/data_display/uten_gauge_ring.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/feedback/uten_batch_reject_dialog.dart';
import 'package:uten_imp/components/feedback/uten_center_alert.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_scoped_badges.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_scope.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _Reviewer extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'a', code: 'QA001', name: '张三'),
  );
}

class _Lite extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.lite;
}

class _Nonlinear extends TextScaler {
  const _Nonlinear();
  @override
  double scale(double fontSize) => fontSize * (fontSize < 20 ? 2 : 1.4);
  @override
  double get textScaleFactor => 2;
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size window = const Size(320, 600),
    TextScaler scaler = TextScaler.noScaling,
    BadgeCounts counts = const BadgeCounts(123, 135),
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(Dio())),
          sessionProvider.overrideWith(_Reviewer.new),
          performanceProvider.overrideWith(_Lite.new),
          currentPermissionsProvider.overrideWithValue({}),
          apiBaseUrlProvider.overrideWithValue('https://test.invalid'),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'a'),
          ),
          badgeScopeCountsProvider.overrideWith((ref, scope) => counts),
        ],
        child: MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.android),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, routed) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scaler),
            child: UtenDisplayZoomBox(
              fontFactor: 2,
              child: UtenControlTheme(child: routed!),
            ),
          ),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('160画布长币种金额、选择清除和提示动作可读换行', (tester) async {
    var clear = 0;
    var action = 0;
    await pump(
      tester,
      SingleChildScrollView(
        child: Column(
          children: [
            const UtenTotalsSummaryBar(
              entries: [
                UtenTotalEntry(
                  '合计金额(很长的国际结算币种名称)',
                  '12345678901234567890.00 美元',
                  danger: true,
                ),
              ],
            ),
            UtenSelectionSummaryPill(
              count: 1234567890,
              clearKey: const Key('clear'),
              onClear: () => clear++,
            ),
            UtenInlineNotice(
              title: '货品已经入库，检查全部储放区域',
              message: '保留库存事实与全部提示文字',
              trailing: FilledButton(
                onPressed: () => action++,
                child: const Text('查看并确认储放区域'),
              ),
            ),
            const UtenStatusBadge(
              label: '等待全部直接材料完成采购入库后审批',
              type: UtenStatusBadgeType.warning,
              icon: Icons.warning,
            ),
          ],
        ),
      ),
    );
    expect(find.text('12345678901234567890.00 美元'), findsOneWidget);
    expect(find.text('已选 1234567890 项'), findsOneWidget);
    final status = find.text('等待全部直接材料完成采购入库后审批');
    expect(tester.widget<Text>(status).maxLines, isNull);
    expect(tester.getRect(status).height, greaterThan(30));
    expect(tester.getRect(status).right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    final clearRect = tester.getRect(find.byKey(const Key('clear')));
    expect(clearRect.width, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const Key('clear')));
    expect(clear, 1);
    await tester.ensureVisible(find.text('查看并确认储放区域'));
    await tester.tap(find.text('查看并确认储放区域'));
    expect(action, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('160画布边缘右键菜单限宽高、全文换行且回调只执行一次', (tester) async {
    var selected = 0;
    UtenContextMenuCloseReason? reason;
    await pump(
      tester,
      Builder(
        builder: (context) => FilledButton(
          onPressed: () async {
            reason = await showUtenContextMenu(
              context,
              globalPosition: const Offset(318, 318),
              entries: [
                UtenMenuItem(
                  label: '复制完整物料信息',
                  icon: Icons.copy,
                  onTap: () => selected++,
                ),
              ],
            );
          },
          child: const Text('打开菜单'),
        ),
      ),
      window: const Size(320, 320),
    );
    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    final label = find.text('复制完整物料信息');
    final rect = tester.getRect(label);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(320));
    expect(tester.widget<Text>(label).maxLines, isNull);
    expect(tester.takeException(), isNull);
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(reason, UtenContextMenuCloseReason.actionCompleted);
  });

  testWidgets('160画布忙碌提示完整可读，展示层不挤成固定图标旁的一列字', (tester) async {
    await pump(
      tester,
      const TickerMode(
        enabled: false,
        child: UtenBusyOverlayCard(
          title: '正在处理批量审核任务',
          description: '全部来源与数量核对完成后自动继续',
          showDoNotLeaveHint: false,
        ),
      ),
      window: const Size(320, 320),
    );
    final description = find.text('全部来源与数量核对完成后自动继续');
    expect(description, findsOneWidget);
    expect(tester.widget<Text>(description).maxLines, isNull);
    expect(tester.getRect(description).width, greaterThan(160));
    expect(tester.getRect(description).right, lessThanOrEqualTo(320));
    expect(find.textContaining('请勿重复点击'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final window in [const Size(320, 600), const Size(320, 320)]) {
    testWidgets('批量驳回200% $window：原因必填，保留责任提示和确认返回值', (tester) async {
      String? returned;
      await pump(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              returned = await showUtenBatchRejectDialog(
                context,
                count: 2,
                actionLabel: '质检驳回',
              );
            },
            child: const Text('打开'),
          ),
        ),
        window: window,
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('审核员：张三(QA001)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const Key('uten-batch-reject-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFieldHintIcon && widget.errorMessage == '请填写驳回原因',
        ),
        findsOneWidget,
      );
      expect(returned, isNull);
      await tester.enterText(
        find.byKey(const Key('uten-batch-reject-reason')),
        '尺寸不符合要求',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('uten-batch-reject-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
      await tester.pumpAndSettle();
      expect(returned, '尺寸不符合要求');
      expect(tester.takeException(), isNull);
    });

    testWidgets('中心紧急提醒200% $window：可滚长文、双动作换行、遮罩不可关闭', (tester) async {
      bool? result;
      await pump(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await UtenCenterAlert.show(
                context,
                title: '紧急设备故障停机提醒',
                message: List.filled(20, '请确认产线设备与现场负责人。').join(),
                level: UtenAlertLevel.urgent,
                cancelLabel: '稍后处理',
                confirmLabel: '已知悉并准备处理',
              );
            },
            child: const Text('打开'),
          ),
        ),
        window: window,
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(find.text('紧急设备故障停机提醒'), findsOneWidget);
      await tester.ensureVisible(find.text('已知悉并准备处理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已知悉并准备处理'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('屏幕打印预览200% $window：工具条换行、纸面可查看、关闭可达', (tester) async {
      await pump(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showUtenPrintPreview(
              context: context,
              title: '供应商明细与物料统计',
              applyTableProjection: false,
              exportEndpoint: '/export',
              exportReport: 'test',
              loader: () async => const UtenPrintTable(
                headers: ['物料', '数量'],
                rows: [
                  ['完整物料名称', '12345'],
                ],
              ),
            ),
            child: const Text('打开'),
          ),
        ),
        window: window,
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      // At 200% zoom the wrapping header can initially occupy the whole
      // viewport. The paper is lazy: reveal it with the same drag a user makes.
      for (
        var attempt = 0;
        attempt < 8 && find.text('完整物料名称').evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(find.byType(NestedScrollView), const Offset(0, -120));
        await tester.pumpAndSettle();
      }
      expect(find.text('完整物料名称'), findsOneWidget);
      expect(find.text('12345'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('关闭'));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('预览 · 供应商明细与物料统计'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('导出密码200%保留确认校验，取消不触发导出', (tester) async {
    await pump(
      tester,
      const UtenExportButton(
        endpoint: '/export',
        report: 'test',
        queryParams: {},
      ),
    );
    await tester.tap(find.text('下载表格'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'abc');
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'different');
    await tester.tap(find.text('加密下载'));
    await tester.pump();
    expect(find.textContaining('一致'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('双徽章160宽系统非线性200%保持黄红顺序、99+与零隐藏', (tester) async {
    const scope = BadgeScope.module(BadgeModule.sales);
    await pump(
      tester,
      const UtenBadgeScale(
        scale: 2.6,
        child: UtenScopedBadges(scope: scope, showLabel: true),
      ),
      scaler: const _Nonlinear(),
    );
    final yellow = tester.getRect(find.byType(UtenInProgressBadge));
    final red = tester.getRect(find.byType(UtenNotificationBadge));
    expect(red.top, greaterThan(yellow.top));
    expect(find.text('99+'), findsNWidgets(2));
    expect(yellow.right, lessThanOrEqualTo(320));
    expect(red.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    await pump(
      tester,
      const UtenScopedBadges(scope: scope),
      counts: BadgeCounts.zero,
    );
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.byType(UtenInProgressBadge), findsNothing);
  });

  testWidgets('仪表长数值和说明200%换到环下且不FittedBox缩小', (tester) async {
    await pump(
      tester,
      const SingleChildScrollView(
        child: UtenGaugeRing(
          value: 99,
          valueText: '123456789012345.6',
          unit: 'GB',
          label: '存储',
          caption: '完整的监控指标与容量说明',
          status: UtenGaugeStatus.warning,
        ),
      ),
      scaler: const _Nonlinear(),
    );
    expect(find.text('123456789012345.6'), findsOneWidget);
    expect(find.byType(FittedBox), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
