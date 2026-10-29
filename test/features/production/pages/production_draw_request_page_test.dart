import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
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
import 'package:uten_imp/shared/auth/session_epoch_provider.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/shared/providers/list_refresh_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

import '../support/production_draw_request_fixture.dart';
import '../../../support/audit_screenshot_support.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';

const _permissions = {
  Perm.productionExecutionView,
  Perm.productionExecutionStart,
};
const _submitKey = Key('production-draw-request-submit');
const _captureScreenshots = bool.fromEnvironment('DRAW_REQUEST_SCREENSHOTS');

class _DrawSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'worker',
      code: 'CJ1',
      name: '车间',
      permissions: [
        Perm.productionExecutionView,
        Perm.productionExecutionStart,
      ],
    ),
  );
}

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
  Set<String>? initialDrawItemIds,
  bool authenticated = false,
  MemoryFormDraftStorage? draftStorage,
  ValueNotifier<Set<String>>? sourceChanges,
  String? resumeId,
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
    initialLocation: Uri(
      path: RouteName.productionDrawRequest,
      queryParameters: {'draftId': ?resumeId},
    ).toString(),
    routes: [
      GoRoute(
        path: RouteName.productionDrawRequest,
        builder: (_, _) => sourceChanges == null
            ? ProductionDrawRequestPage(
                segmentIds: segmentIds,
                expectedVersions: versions,
                initialDrawItemIds: initialDrawItemIds,
              )
            : ValueListenableBuilder<Set<String>>(
                valueListenable: sourceChanges,
                builder: (_, selected, _) => ProductionDrawRequestPage(
                  segmentIds: segmentIds,
                  expectedVersions: versions,
                  initialDrawItemIds: selected,
                ),
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
        if (authenticated) sessionProvider.overrideWith(_DrawSession.new),
        if (draftStorage != null)
          formDraftStorageProvider.overrideWithValue(draftStorage),
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
  testWidgets(
    'reused page cannot apply an old preview to changed source selection',
    (tester) async {
      final changes = ValueNotifier<Set<String>>({'line-b'});
      addTearDown(changes.dispose);
      final repository = _Repository()..previewGate = Completer<void>();
      await _pump(tester, repository, sourceChanges: changes, settle: false);
      changes.value = {'line-a'};
      await tester.pump();
      repository.previewGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(_submitKey), findsNothing);
      expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
      expect(repository.submissions, isEmpty);
      expect(repository.previews, hasLength(1));
    },
  );
  for (final scopeOnly in [false, true]) {
    testWidgets(
      'late selected-source preview is rejected after ${scopeOnly ? 'read scope' : 'login'} changes',
      (tester) async {
        final repository = _Repository()..previewGate = Completer<void>();
        final container = await _pump(
          tester,
          repository,
          initialDrawItemIds: {'line-b'},
          authenticated: true,
          settle: false,
        );
        if (scopeOnly) {
          container.read(readScopeRevisionProvider.notifier).state++;
        } else {
          container.read(sessionEpochProvider.notifier).state++;
        }
        repository.previewGate!.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(_submitKey), findsNothing);
        expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
        expect(repository.submissions, isEmpty);
      },
    );
  }
  testWidgets(
    'scope invalidation during submit retains original unknown command draft',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      final pending = Completer<ProductionDrawRequestResult>();
      final repository = _Repository()..pendingSubmit = pending;
      final container = await _pump(
        tester,
        repository,
        initialDrawItemIds: {'line-b'},
        authenticated: true,
        draftStorage: storage,
      );
      await tester.tap(find.byKey(_submitKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repository.submissions, hasLength(1));
      expect(storage.records, hasLength(1));
      final before = storage.records.values.single;
      final saved = FormDraft.fromJson(
        jsonDecode(before) as Map<String, dynamic>,
      );
      expect(saved.hasUnknownSubmission, isTrue);
      expect((saved.data['preview'] as Map)['lines'], [
        containsPair('drawItemId', 'line-b'),
      ]);
      container.read(readScopeRevisionProvider.notifier).state++;
      pending.complete(
        ProductionDrawRequestResult.fromJson(
          productionDrawRequestResultFixture,
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.submissions, hasLength(1));
      expect(
        storage.records.values.single,
        before,
        reason: '旧命令响应不能清除或覆盖原账号的未知提交证据',
      );
      expect(find.text('我的车间任务已刷新'), findsNothing);
      expect(find.byKey(_submitKey), findsNothing);
      final replay = _Repository();
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(
        tester,
        replay,
        initialDrawItemIds: {'line-b'},
        authenticated: true,
        draftStorage: storage,
        resumeId: saved.id,
      );
      expect(find.text('重试领料'), findsOneWidget);
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(replay.submissions, hasLength(1));
      expect(
        replay.submissions.single,
        repository.submissions.single,
        reason: '重开草稿只重放原fingerprint/版本/来源/数量/幂等标识',
      );
    },
  );
  testWidgets(
    'material dialog selection submits only the chosen original source',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository, initialDrawItemIds: {'line-b'});
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();
      expect(repository.submissions.single['lines'], [
        {'drawItemId': 'line-b', 'quantity': 4.0},
      ]);
      expect(
        repository.submissions.single['previewFingerprint'],
        'preview-fingerprint',
      );
    },
  );

  testWidgets('explicit empty dialog selection never turns into select all', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository, initialDrawItemIds: {});
    expect(find.byKey(_submitKey), findsNothing);
    expect(find.text('暂无可领物料'), findsOneWidget);
    expect(repository.submissions, isEmpty);
  });
  // 2026-09-21 用户口径「批量领料也要和别的页面一样有中间的加载弹窗」: 车间任务页
  // 点「批量领料」是跳到本页, 遮罩挂着跳会把本页整片盖住(root Overlay 裸 entry),
  // 所以实际加载遮罩由目标页首屏持有，网络完成后必须撤下。
  testWidgets('first paint shows the shared modal loading overlay', (
    tester,
  ) async {
    final repository = _Repository()..previewGate = Completer<void>();
    await _pump(tester, repository, settle: false);
    expect(
      find.byKey(const Key('production-draw-request-loading')),
      findsOneWidget,
    );
    expect(find.text('正在加载领料汇总'), findsOneWidget);
    expect(find.byType(UtenBusyOverlay), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ModalBarrier &&
            !widget.dismissible &&
            widget.color != null,
      ),
      findsOneWidget,
    );
    repository.previewGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('production-draw-request-loading')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed initial read removes the modal and leaves the review route available',
    (tester) async {
      final repository = _Repository()
        ..previewGate = Completer<void>()
        ..previewError = ApiException('CONFLICT', '所选工单已变化', httpStatus: 409);
      await _pump(tester, repository, settle: false);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      repository.previewGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.byType(ProductionDrawRequestPage), findsOneWidget);
      expect(find.text('重新加载').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
      // 2026-10-10 数量内联口径：单位撤销独立列，待申请量/本次领料数字直接带单位。
      expect(find.text('1.5 个'), findsOneWidget);
      await tester.tap(find.byType(UtenCloseButton).last);
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
      expect(tester.widget<TextField>(quantity).decoration!.hintText, '应领数量');
      for (final invalid in ['', '0', '-1', '8', 'NaN', '1.00001']) {
        await tester.enterText(quantity, invalid);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(quantity).controller!.text, invalid);
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
  testWidgets(
    'quantity column keeps guidance in the header only (no cell caption, no per-cell info icon)',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      // 表头：应领数量列带列头 ⓘ——列含义说明的唯一入口（全站口径）。
      expect(find.byType(UtenColumnHintIcon), findsOneWidget);
      // 单元格：不再有浮动标签「本次领料」角标；格内 ⓘ（非紧凑
      // UtenFieldHintIcon）在数据合法时不应出现（表头 ⓘ 是 dense 态）。
      expect(find.text('本次领料'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UtenFieldHintIcon && !widget.dense,
        ),
        findsNothing,
      );
      // 语义：删掉 labelText 后由表格列包装兜底，读屏仍有等价列名与当前值。
      expect(find.bySemanticsLabel(RegExp('应领数量: 7')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('应领数量: 2')), findsOneWidget);
      // 行级校验反馈不受影响：超上限时错误披露图标（非紧凑）回到该格。
      await tester.enterText(
        find.byKey(
          const ValueKey(
            'production-draw-quantity-warehouse-a|goods|silver|unit',
          ),
        ),
        '8',
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UtenFieldHintIcon && !widget.dense,
        ),
        findsOneWidget,
      );
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
      final refresh = tester.widget<UtenRefreshButton>(
        find.byKey(const Key('production-draw-request-refresh')),
      );
      expect(refresh.enabled, isFalse);
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
      final back = find.byType(UtenBackButton);
      expect(tester.widget<UtenBackButton>(back).enabled, isFalse);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: back, matching: find.byType(IconButton)),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(back, warnIfMissed: false);
      await tester.pump();
      expect(find.byType(ProductionDrawRequestPage), findsOneWidget);
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
    final back = find.byType(UtenBackButton);
    expect(tester.widget<UtenBackButton>(back).enabled, isFalse);
    expect(
      tester
          .widget<IconButton>(
            find.descendant(of: back, matching: find.byType(IconButton)),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(back, warnIfMissed: false);
    await tester.pump();
    expect(find.byType(ProductionDrawRequestPage), findsOneWidget);
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
