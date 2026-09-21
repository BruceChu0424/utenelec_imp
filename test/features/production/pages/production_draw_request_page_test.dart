import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/models/production_draw_request.dart';
import 'package:uten_imp/features/production/pages/production_draw_request_page.dart';
import 'package:uten_imp/features/production/providers/production_execution_refresh.dart';
import 'package:uten_imp/features/production/repositories/production_draw_request_repository.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/list_refresh_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../support/production_draw_request_fixture.dart';
import '../../../support/audit_screenshot_support.dart';

const _permissions = {
  Perm.productionExecutionView,
  Perm.productionExecutionStart,
};
const _submitKey = Key('production-draw-request-submit');
const _captureScreenshots = bool.fromEnvironment('DRAW_REQUEST_SCREENSHOTS');

class _Repository extends ProductionDrawRequestRepository {
  _Repository() : super(ApiClient(Dio()));

  final previews = <List<ProductionDrawRequestItem>>[];
  final submissions = <Map<String, dynamic>>[];
  Object? previewError;
  Object? submitError;
  Completer<ProductionDrawRequestResult>? pendingSubmit;

  /// 挂起首屏汇总查询(加载卡片测试用): 非空时 preview 停在这个 future 上。
  Completer<void>? previewGate;
  Map<String, dynamic> previewJson = productionDrawRequestFixture();

  @override
  Future<ProductionDrawRequestPreview> preview(
    List<ProductionDrawRequestItem> items,
  ) async {
    previews.add(items);
    final gate = previewGate;
    if (gate != null) await gate.future;
    if (previewError != null) throw previewError!;
    return ProductionDrawRequestPreview.fromJson(previewJson);
  }

  @override
  Future<ProductionDrawRequestResult> submit({
    required List<ProductionDrawRequestItem> items,
    required String idempotencyKey,
    required String previewFingerprint,
    List<ProductionDrawRequestSelection>? lines,
  }) async {
    submissions.add({
      'items': items.map((item) => item.toJson()).toList(),
      'idempotencyKey': idempotencyKey,
      'previewFingerprint': previewFingerprint,
      if (lines != null) 'lines': lines.map((line) => line.toJson()).toList(),
    });
    if (submitError != null) throw submitError!;
    if (pendingSubmit != null) return pendingSubmit!.future;
    return ProductionDrawRequestResult.fromJson({
      ...productionDrawRequestResultFixture,
      'replayed': submissions.length > 1,
    });
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  Set<String> permissions = _permissions,
  Size size = const Size(1400, 900),
  List<String> segmentIds = const ['b', 'a'],
  Map<String, int> versions = const {'a': 6, 'b': 6},
  bool dark = false,
  double textScale = 1,
  GlobalKey? captureKey,
  // 首屏加载卡片里的转圈是无限动画: 要观察加载态就不能 pumpAndSettle。
  bool settle = true,
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
    initialLocation: '/draw-request',
    routes: [
      GoRoute(
        path: '/draw-request',
        builder: (_, _) => ProductionDrawRequestPage(
          segmentIds: segmentIds,
          expectedVersions: versions,
        ),
      ),
      GoRoute(
        path: RouteName.productionWorkshopTasks,
        builder: (_, _) => const Scaffold(body: Text('我的车间任务已刷新')),
      ),
    ],
  );
  addTearDown(router.dispose);
  var theme = dark ? buildDarkTheme() : buildLightTheme();
  if (_captureScreenshots) {
    theme = auditScreenshotTheme(theme);
    // The widget binding injects Ahem into default dialog title styles too.
    theme = theme.copyWith(
      dialogTheme: theme.dialogTheme.copyWith(
        titleTextStyle: theme.textTheme.headlineSmall,
        contentTextStyle: theme.textTheme.bodyMedium,
      ),
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        productionDrawRequestRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        theme: theme,
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
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  expect(tester.takeException(), isNull);
  return ProviderScope.containerOf(
    tester.element(find.byType(ProductionDrawRequestPage)),
  );
}

void main() {
  // 2026-09-21 用户口径「批量领料也要和别的页面一样有中间的加载弹窗」: 车间任务页
  // 点「批量领料」是跳到本页, 遮罩挂着跳会把本页整片盖住(root Overlay 裸 entry),
  // 所以加载反馈落在本页首屏——用全站同款的居中加载卡片替掉原来的裸转圈。这里
  // 用卡片本体而不是 UtenBusyOverlay: 遮罩带不可关闭的 ModalBarrier, 首屏还在
  // 加载时会把返回按钮一起吃掉。
  testWidgets('first paint shows the shared centered loading card', (
    tester,
  ) async {
    final repository = _Repository()..previewGate = Completer<void>();
    await _pump(tester, repository, settle: false);
    expect(
      find.byKey(const Key('production-draw-request-loading')),
      findsOneWidget,
    );
    expect(find.text('正在加载领料汇总'), findsOneWidget);
    // 返回按钮不能被蒙版吃掉: 首屏加载用的是卡片本体, 不是带不可关闭蒙版的遮罩。
    expect(find.byType(UtenBusyOverlay), findsNothing);
    repository.previewGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('production-draw-request-loading')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selected material quantity is allocated to exact reviewed sources',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.enterText(
        find.byKey(
          const ValueKey(
            'production-draw-quantity-warehouse-a|goods|silver|unit',
          ),
        ),
        '4.5',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 个任务 · 查看明细'));
      await tester.pumpAndSettle();
      expect(find.text('1.5'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(repository.submissions.single['lines'], [
        {'drawItemId': 'line-a', 'quantity': 3.0},
        {'drawItemId': 'line-b', 'quantity': 1.5},
      ]);
      expect(repository.submissions.single['items'], hasLength(2));
    },
  );

  testWidgets(
    'empty selection and invalid quantities block submission inside the field',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      final quantity = find.byKey(
        const ValueKey(
          'production-draw-quantity-warehouse-a|goods|silver|unit',
        ),
      );
      for (final invalid in ['0', '-1', '8', 'NaN', '1.00001']) {
        await tester.enterText(quantity, invalid);
        await tester.pumpAndSettle();
        expect(
          tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed,
          isNull,
        );
      }
      await tester.enterText(quantity, '0.125');
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed,
        isNotNull,
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed,
        isNull,
      );
      expect(repository.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('entry only previews and summaries retain exact task sources', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);

    expect(repository.previews.single.map((item) => item.toJson()), [
      {'segmentId': 'a', 'expectedVersion': 6},
      {'segmentId': 'b', 'expectedVersion': 6},
    ]);
    expect(repository.submissions, isEmpty);
    expect(find.text('2 个车间任务 · 2 项领料汇总 · 2 张领料单'), findsOneWidget);
    expect(find.text('2 个任务 · 查看明细'), findsOneWidget);
    await tester.tap(find.text('2 个任务 · 查看明细'));
    await tester.pumpAndSettle();
    expect(find.text('SC-a'), findsOneWidget);
    expect(find.text('SC-b'), findsOneWidget);
    expect(find.text('LL-a'), findsOneWidget);
    expect(find.text('LL-b'), findsOneWidget);
    expect(repository.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'explicit submit uses preview versions and refreshes both workflows',
    (tester) async {
      final repository = _Repository();
      final container = await _pump(tester, repository);
      final executionBefore = container.read(
        listRefreshTickProvider(productionExecutionRefreshKey),
      );
      final drawBefore = container.read(
        listRefreshTickProvider(StockDocType.draw.refreshKey),
      );

      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();

      expect(repository.submissions.single['items'], [
        {'segmentId': 'a', 'expectedVersion': 7},
        {'segmentId': 'b', 'expectedVersion': 7},
      ]);
      expect(
        repository.submissions.single['previewFingerprint'],
        'preview-fingerprint',
      );
      expect(
        container.read(listRefreshTickProvider(productionExecutionRefreshKey)),
        executionBefore + 1,
      );
      expect(
        container.read(listRefreshTickProvider(StockDocType.draw.refreshKey)),
        drawBefore + 1,
      );
      expect(find.text('我的车间任务已刷新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lost submit response retries the same reviewed request without refreshing',
    (tester) async {
      final repository = _Repository()..submitError = NetworkTimeoutException();
      await _pump(tester, repository);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();

      expect(find.text('重试领料'), findsOneWidget);
      final refresh = tester.widget<IconButton>(
        find.byKey(const Key('production-draw-request-refresh')),
      );
      expect(refresh.onPressed, isNull);
      expect(
        tester
            .widget<TextField>(
              find.byKey(
                const ValueKey(
                  'production-draw-quantity-warehouse-a|goods|silver|unit',
                ),
              ),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester.widget<PopScope>(find.byType(PopScope).first).canPop,
        isFalse,
      );
      repository.submitError = null;
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();

      expect(repository.previews, hasLength(1));
      expect(repository.submissions, hasLength(2));
      expect(repository.submissions[0], repository.submissions[1]);
      expect(find.text('我的车间任务已刷新'), findsOneWidget);
    },
  );

  testWidgets(
    'version conflict blocks submit until fresh preview is reviewed',
    (tester) async {
      final repository = _Repository()
        ..submitError = ApiException('CONFLICT', '库存已变化', httpStatus: 409);
      await _pump(tester, repository);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed,
        isNull,
      );
      expect(find.textContaining('库存已变化'), findsOneWidget);

      repository.submitError = null;
      repository.previewJson = productionDrawRequestFixture(
        version: 8,
        fingerprint: 'fresh-preview',
      );
      await tester.tap(find.text('重新加载并核对'));
      await tester.pumpAndSettle();
      expect(
        repository.previews.last.every((item) => item.expectedVersion == null),
        isTrue,
      );
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(
        repository.submissions.last['previewFingerprint'],
        'fresh-preview',
      );
      expect(
        repository.submissions.last['idempotencyKey'],
        isNot(repository.submissions.first['idempotencyKey']),
      );
    },
  );

  testWidgets('permission gate prevents preview and submit requests', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(
      tester,
      repository,
      permissions: {Perm.productionExecutionView},
    );
    expect(repository.previews, isEmpty);
    expect(repository.submissions, isEmpty);
    expect(find.text('当前账号没有查看并提交车间领料的权限'), findsOneWidget);
    expect(find.byKey(_submitKey), findsNothing);
  });

  testWidgets(
    'preview error offers retry and direct links can fetch current versions',
    (tester) async {
      final repository = _Repository()..previewError = NetworkException();
      await _pump(tester, repository, versions: const {});
      expect(find.text('重新加载'), findsOneWidget);
      expect(find.byKey(_submitKey), findsNothing);
      repository.previewError = null;
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(repository.previews, hasLength(2));
      expect(
        repository.previews.last.every((item) => item.expectedVersion == null),
        isTrue,
      );
      expect(find.byKey(_submitKey), findsOneWidget);
    },
  );

  testWidgets('empty preview has a return path and no submit action', (
    tester,
  ) async {
    final repository = _Repository()
      ..previewJson = {
        ...productionDrawRequestFixture(),
        'summaries': <Map<String, dynamic>>[],
        'lines': <Map<String, dynamic>>[],
      };
    await _pump(tester, repository);
    expect(find.text('暂无可领物料'), findsOneWidget);
    expect(find.text('返回我的车间任务'), findsOneWidget);
    expect(find.byKey(_submitKey), findsNothing);
  });

  testWidgets('pending submission blocks duplicate clicks and navigation', (
    tester,
  ) async {
    final repository = _Repository()
      ..pendingSubmit = Completer<ProductionDrawRequestResult>();
    await _pump(tester, repository);
    await tester.tap(find.byKey(_submitKey));
    await tester.pump();
    expect(tester.widget<UtenButton>(find.byKey(_submitKey)).onPressed, isNull);
    expect(repository.submissions, hasLength(1));
    expect(
      tester.widget<PopScope>(find.byType(PopScope).first).canPop,
      isFalse,
    );
    repository.pendingSubmit!.complete(
      ProductionDrawRequestResult.fromJson(productionDrawRequestResultFixture),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的车间任务已刷新'), findsOneWidget);
  });

  testWidgets(
    'compact viewport retains the summary and final action without overflow',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository, size: const Size(390, 844));
      expect(find.byKey(_submitKey), findsOneWidget);
      expect(
        find.byKey(const Key('production-draw-request-summary-table')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'visual review ${dark ? 'compact dark scaled' : 'desktop light sources'}',
      (tester) async {
        if (_captureScreenshots) await loadAuditScreenshotFonts(tester);
        final boundary = GlobalKey();
        await _pump(
          tester,
          _Repository(),
          size: dark ? const Size(390, 844) : const Size(1400, 900),
          dark: dark,
          textScale: dark ? 1.3 : 1,
          captureKey: boundary,
        );
        expect(find.byKey(_submitKey), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (_captureScreenshots) {
          await saveAuditScreenshot(
            tester,
            boundary,
            dark ? 'draw-request-compact-dark' : 'draw-request-desktop-light',
          );
        }
        if (!dark) {
          await tester.tap(find.text('2 个任务 · 查看明细'));
          await tester.pumpAndSettle();
          expect(find.text('SC-a'), findsOneWidget);
          expect(find.text('SC-b'), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (_captureScreenshots) {
            await saveAuditScreenshot(
              tester,
              boundary,
              'draw-request-desktop-sources',
            );
          }
        }
      },
    );
  }
}
