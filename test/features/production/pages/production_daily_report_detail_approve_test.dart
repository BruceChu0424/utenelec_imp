// 生产日报详情页「审核」回归(2026-09-21 事故)。
//
// 事故复盘：服务端 15.094 秒返回 200 并已提交，浏览器 15 秒就掐了连接，页面因此停在草稿，
// 「审核」按钮还在，用户 45 秒后又点了一次，服务端回「仅草稿单据可审核」400。
// 这里钉住三件事：
//   1) 拿到 200 就必须翻成已审核，且不再多发一次详情请求；
//   2) 写请求结果未知时保留原命令；当前状态不能替代原命令的可核对回执；
//   3) 服务端明确拒绝且状态确实没变时，仍旧报错、不乱改页面。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_empty.dart';
import 'package:uten_imp/components/feedback/uten_skeleton.dart';
import 'package:uten_imp/components/feedback/uten_reviewer_responsibility_notice.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/daily_report_approval_intent.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_detail_page.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../support/document_scope_capability_overrides.dart';
import '../../../support/audit_screenshot_support.dart';
import '../../../support/memory_cas_storage.dart';

part 'production_daily_report_review_v2_cases.dart';

final _scope = StateProvider<AuthenticatedScope>(
  (ref) => const AuthenticatedScope(userId: 'daily-report-tester'),
);
final _server = StateProvider<String>(
  (ref) => 'https://daily-report.example/api',
);

class _ApprovalSession extends SessionNotifier {
  int intentEpoch = 0;
  @override
  int get requestIntentEpoch => intentEpoch;
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'daily-report-tester', code: 'reviewer', name: '审核员'),
  );
}

/// 服务端替身：状态是它自己的事实，post 只决定「客户端这次拿不拿得到结果」。
class _DailyReportApi extends ApiClient {
  _DailyReportApi({required this.onApprove, MemoryCasStorage? storage})
    : approvalStorage = storage ?? MemoryCasStorage(),
      super(Dio());

  /// 返回 null 表示这次审核正常拿到响应；返回异常表示响应丢了(超时/断连)或被拒。
  final Object? Function(_DailyReportApi server) onApprove;

  int serverStatus = 0;
  int detailReads = 0;

  /// 服务端是否还允许当前账号审核这张草稿(permissions-15：权限码 + 对象范围 +
  /// 车间直送审核权由服务端一次算好，随详情下发 allowedActions)。
  bool approvable = true;
  final requestedPaths = <String>[];
  final approveKeys = <String>[];
  int rowVersion = 0;
  Object? capability;
  bool omitVersion = false;
  Object? versionOverride;
  int quantity = 1000;
  bool includeReceipt = false;
  bool allowEdit = false;
  final approveBodies = <Map<String, dynamic>>[];
  String receiptStatus = 'UNCONFIRMED';
  Map<String, dynamic>? receipt;
  Object? receiptFailure;
  int receiptReads = 0;
  Object? readFailure;
  Completer<void>? readGate;
  Completer<void>? commandGate;
  int deletions = 0;
  final notifications = <AppNotification>[];
  final MemoryCasStorage approvalStorage;
  late ProviderContainer container;
  GoRouter? router;

  void rememberApproval({int? protocol, int? version, bool replay = false}) {
    final body = approveBodies.last;
    receipt = {
      'reportId': 'dr-1',
      'idempotencyKey': body['idempotencyKey'],
      'commandVersion': protocol ?? body['commandVersion'],
      'reviewedVersion': version ?? body['expectedVersion'],
      'replay': replay,
    };
    receiptStatus = 'CONFIRMED';
  }

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': 'dr-1',
    'billNo': 'SR20260922000005',
    'billDate': '2026-09-22',
    'makerName': '朱振炜',
    'makerId': 'maker-1',
    'createdAt': '2026-09-22T05:49:19+08:00',
    'status': serverStatus,
    if (!omitVersion) 'rowVersion': versionOverride ?? rowVersion,
    if (capability != null) 'approvalCommandVersion': capability,
    'allowedActions': <String>[
      if (serverStatus == 0 && approvable) 'APPROVE',
      if (allowEdit) 'EDIT',
    ],
    'departmentName': '六车间',
    'workerIds': <String>['emp-1'],
    'workerNames': <String>['王小明'],
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'di-1',
        'qty': quantity,
        'defectQty': 12.5,
        'planNo': 'SJ20260922000016',
        'goodsId': 'g-1',
        'goodsName': '外贸V5多功能三插后座',
        'goodsCode': 'HV50070',
        'colorName': '深灰色',
        'unitName': '只',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requestedPaths.add(path);
    if (path.endsWith('/approval-receipt')) {
      receiptReads++;
      if (receiptFailure case final failure?) throw failure;
      return {'status': receiptStatus, 'receipt': receipt, 'detail': _detail};
    }
    if (path == '/auth/me') {
      return {
        'session': {
          'delegableSurfaceKeys': <String>[],
          'documentScopes': <String, Object>{},
          'preferences': <String, Object>{},
        },
      };
    }
    if (path == '/workbench/badges') {
      return {
        'entries': <String, Object>{},
        'modules': <String, Object>{},
        'totals': <String, Object>{},
      };
    }
    detailReads++;
    await readGate?.future;
    if (readFailure case final failure?) throw failure;
    return _detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requestedPaths.add(path);
    return const <Map<String, dynamic>>[];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requestedPaths.add(path);
    final key = (body as Map?)?['idempotencyKey'];
    if (key is String) approveKeys.add(key);
    if (path.endsWith('/approve')) {
      approveBodies.add(Map<String, dynamic>.from(body as Map));
    }
    await commandGate?.future;
    final failure = onApprove(this);
    if (failure != null) throw failure;
    return {
      ..._detail,
      if (includeReceipt && receipt != null) 'approvalReceipt': receipt,
    };
  }

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    requestedPaths.add(path);
    deletions++;
    await commandGate?.future;
  }
}

Future<(_DailyReportApi, List<String>)> _pump(
  WidgetTester tester, {
  required Object? Function(_DailyReportApi server) onApprove,
  bool approvable = true,
  bool fromWorkshop = false,
  int status = 0,
  Object? readFailure,
  Completer<void>? commandGate,
  Size size = const Size(1400, 1000),
  Locale locale = const Locale('zh'),
  bool dark = false,
  double textScale = 1,
  GlobalKey? captureKey,
  bool showNotifications = false,
  Object? capability,
  bool omitVersion = false,
  Object? versionOverride,
  MemoryCasStorage? storage,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final api = _DailyReportApi(onApprove: onApprove, storage: storage)
    ..capability = capability
    ..omitVersion = omitVersion
    ..versionOverride = versionOverride
    ..approvable = approvable
    ..serverStatus = status
    ..readFailure = readFailure
    ..commandGate = commandGate;
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      apiClientProvider.overrideWithValue(api),
      sessionProvider.overrideWith(_ApprovalSession.new),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      formDraftStorageProvider.overrideWithValue(api.approvalStorage),
      // 本地服务可达性探针带 60 秒周期 Timer，测试收尾会判「Timer 未清」。
      // 按 Web 形态构造就整体不起探针(它在 Web 上本来也不跑)。
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(preferences, web: true),
      ),
      productionWriteAllDocumentScope(),
      masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      currentPermissionsProvider.overrideWithValue(const <String>{
        Perm.productionDailyReportView,
        Perm.productionDailyReportEdit,
        Perm.productionDailyReportApprove,
        Perm.productionDailyReportReverse,
        Perm.productionDailyReportDelete,
        Perm.attachmentView,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      businessAttachmentsProvider.overrideWith(
        (ref, owner) async => const <Attachment>[],
      ),
    ],
  );
  api.container = container;

  // 通知条自带停留计时，pumpAndSettle 会把它推过期；边产生边记，断言才稳。
  final notices = <String>[];
  container.listen<List<AppNotification>>(appNotificationProvider, (
    previous,
    next,
  ) {
    notices.addAll(next.map((item) => item.message));
    api.notifications.addAll(next);
  }, fireImmediately: true);

  final router = fromWorkshop
      ? GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('已回车间任务')),
            ),
            GoRoute(
              path: '/report/:id',
              builder: ProductionDailyReportDetailPage.route,
            ),
            GoRoute(
              path: '/cover',
              builder: (_, _) => const Scaffold(body: Text('覆盖页面')),
            ),
            GoRoute(
              path: '/production/daily-reports/:id/edit',
              builder: (context, state) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    api.rowVersion++;
                    context.pop('dr-1');
                  },
                  child: Text('保存编辑 ${state.uri.queryParameters['from']}'),
                ),
              ),
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  api.router = router;
  final theme = dark ? buildDarkTheme() : buildLightTheme();
  final screenshotTheme = auditScreenshotTheme(theme);
  final renderedTheme = captureKey == null
      ? theme
      : screenshotTheme.copyWith(
          dialogTheme: screenshotTheme.dialogTheme.copyWith(
            titleTextStyle:
                (theme.dialogTheme.titleTextStyle ?? theme.textTheme.titleLarge)
                    ?.copyWith(fontFamily: 'NotoSansSC'),
            contentTextStyle:
                (theme.dialogTheme.contentTextStyle ??
                        theme.textTheme.bodyMedium)
                    ?.copyWith(fontFamily: 'NotoSansSC'),
          ),
        );
  Widget builder(BuildContext context, Widget? child) {
    final content = MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: showNotifications
          ? Stack(
              children: [
                child!,
                const Align(
                  alignment: Alignment.topCenter,
                  child: AppNotificationHost(),
                ),
              ],
            )
          : child!,
    );
    return captureKey == null
        ? content
        : RepaintBoundary(key: captureKey, child: content);
  }

  await tester.pumpWidget(
    _OwnedApprovalContainer(
      key: UniqueKey(),
      container: container,
      child: router != null
          ? MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              theme: renderedTheme,
              builder: builder,
            )
          : MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              theme: renderedTheme,
              builder: builder,
              home: const ProductionDailyReportDetailPage(id: 'dr-1'),
            ),
    ),
  );
  await tester.pumpAndSettle();
  if (router != null) {
    router.push<void>('/report/dr-1?from=workshop-tasks');
    await tester.pumpAndSettle();
  }
  return (api, notices);
}

class _OwnedApprovalContainer extends StatefulWidget {
  const _OwnedApprovalContainer({
    super.key,
    required this.container,
    required this.child,
  });
  final ProviderContainer container;
  final Widget child;
  @override
  State<_OwnedApprovalContainer> createState() =>
      _OwnedApprovalContainerState();
}

class _OwnedApprovalContainerState extends State<_OwnedApprovalContainer> {
  @override
  void dispose() {
    widget.container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: widget.container,
    child: widget.child,
  );
}

Future<void> _tapApprove(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.widgetWithText(UtenButton, '审核'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  registerDailyReportReviewV2Cases();
  for (final responseLost in [false, true]) {
    testWidgets(
      'a reversed authoritative state does not report approval success: $responseLost',
      (tester) async {
        final capture =
            Platform.environment['UTEN_CAPTURE_DAILY_REPORT_UI'] == 'true';
        final key = capture ? GlobalKey() : null;
        if (capture) await loadAuditScreenshotFonts(tester);
        final (api, notices) = await _pump(
          tester,
          fromWorkshop: true,
          size: capture && responseLost
              ? const Size(375, 844)
              : const Size(1440, 1000),
          dark: capture && !responseLost,
          textScale: capture ? 1.5 : 1,
          captureKey: key,
          showNotifications: capture,
          onApprove: (server) {
            server.serverStatus = -1;
            return responseLost ? NetworkTimeoutException() : null;
          },
        );
        await _tapApprove(tester, settle: !capture);
        expect(
          api.notifications.where(
            (notice) => notice.kind == AppNotificationKind.success,
          ),
          isEmpty,
        );
        expect(
          notices,
          contains(
            responseLost
                ? '当前显示已红冲，但原提交结果仍待核对。原内容已保留。'
                : '日报状态已变化，页面已刷新，请核对当前状态。',
          ),
        );
        expect(find.byType(ProductionDailyReportDetailPage), findsOneWidget);
        expect(find.text('已回车间任务'), findsNothing);
        expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
        if (key != null) {
          expect(
            find.text(
              responseLost
                  ? '当前显示已红冲，但原提交结果仍待核对。原内容已保留。'
                  : '日报状态已变化，页面已刷新，请核对当前状态。',
            ),
            findsWidgets,
          );
          expect(tester.takeException(), isNull);
          await saveAuditScreenshot(
            tester,
            key,
            responseLost
                ? 'daily-report-state-changed-375-light'
                : 'daily-report-state-changed-1440-dark',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );
  }

  testWidgets(
    'a different authoritative state does not report reversal success',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        status: 1,
        onApprove: (server) {
          server.serverStatus = 0;
          return NetworkTimeoutException();
        },
      );
      await tester.tap(find.widgetWithText(UtenButton, '红冲'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(UtenButton, '确认'));
      await tester.pumpAndSettle();
      expect(
        api.notifications.where(
          (notice) => notice.kind == AppNotificationKind.success,
        ),
        isEmpty,
      );
      expect(notices, contains('日报状态已变化，页面已刷新，请核对当前状态。'));
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
    },
  );

  testWidgets('reversal timeout reports only the verified current state', (
    tester,
  ) async {
    final (_, notices) = await _pump(
      tester,
      status: 1,
      onApprove: (server) {
        server.serverStatus = -1;
        return NetworkTimeoutException();
      },
    );
    await tester.tap(find.widgetWithText(UtenButton, '红冲'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(UtenButton, '确认'));
    await tester.pumpAndSettle();
    expect(notices, contains('当前已红冲，页面已刷新。'));
    expect(notices.any((message) => message.contains('本次提交')), isFalse);
    expect(find.widgetWithText(UtenButton, '红冲'), findsNothing);
  });

  testWidgets(
    'completed action does not pop a new route opened during its final frame',
    (tester) async {
      late BuildContext reportContext;
      final (api, _) = await _pump(
        tester,
        fromWorkshop: true,
        onApprove: (server) {
          server.serverStatus = 1;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(reportContext).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('另一个页面')),
              ),
            );
          });
          return null;
        },
      );
      reportContext = tester.element(
        find.byType(ProductionDailyReportDetailPage),
      );
      await _tapApprove(tester);
      expect(find.text('另一个页面'), findsOneWidget);
      expect(find.text('已回车间任务'), findsNothing);
      expect(api.approveKeys, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed detail can retry with a shared loading state and no stale actions',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        onApprove: (_) => null,
        readFailure: Exception('load failed'),
      );
      expect(find.byType(UtenEmpty), findsOneWidget);
      expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
      expect(find.text('加载详情失败，请重试'), findsOneWidget);

      api.readFailure = null;
      api.readGate = Completer<void>();
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pump();
      expect(find.byType(UtenSkeletonList), findsOneWidget);
      expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
      api.readGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenEmpty), findsNothing);
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
      expect(api.detailReads, 2);
      expect(api.approveKeys, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [Locale('en'), Locale('ko')]) {
    testWidgets('detail retry uses ${locale.languageCode} localization', (
      tester,
    ) async {
      await _pump(
        tester,
        onApprove: (_) => null,
        readFailure: Exception('failed'),
        locale: locale,
      );
      final context = tester.element(
        find.byType(ProductionDailyReportDetailPage),
      );
      final l10n = AppLocalizations.of(context);
      expect(find.text(l10n.productionDailyReportLoadFailed), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, l10n.commonRetry),
        findsOneWidget,
      );
    });
  }

  testWidgets(
    'refresh failure hides old draft actions until fresh details arrive',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        fromWorkshop: true,
        onApprove: (_) => null,
      );
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
      api.readFailure = NetworkTimeoutException();
      await tester.tap(find.widgetWithText(UtenButton, '编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存编辑 workshop-tasks'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenEmpty), findsOneWidget);
      expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
      expect(find.widgetWithText(UtenButton, '删除'), findsNothing);
      api.readFailure = null;
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
      expect(api.approveKeys, isEmpty);
    },
  );

  for (final responseLost in [false, true]) {
    testWidgets(
      'busy approval blocks system back; only acknowledged success returns: $responseLost',
      (tester) async {
        final gate = Completer<void>();
        final (api, _) = await _pump(
          tester,
          fromWorkshop: true,
          commandGate: gate,
          onApprove: (server) {
            server.serverStatus = 1;
            return responseLost ? NetworkTimeoutException() : null;
          },
        );
        await tester.tap(find.widgetWithText(UtenButton, '审核'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
        await tester.pump();
        await tester.pump();
        expect(find.byType(UtenBusyOverlay), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.byType(ProductionDailyReportDetailPage), findsOneWidget);
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('已回车间任务'),
          responseLost ? findsNothing : findsOneWidget,
        );
        if (responseLost) {
          expect(
            find.byKey(const Key('daily-report-resolve-approval')),
            findsOneWidget,
          );
        }
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(api.approveKeys, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'reversal uses the shared danger confirmation and cancellation writes nothing',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        status: 1,
        onApprove: (server) {
          server.serverStatus = -1;
          return null;
        },
      );
      await tester.tap(find.widgetWithText(UtenButton, '红冲'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(UtenButton, '确认');
      expect(tester.widget<UtenButton>(confirm).type, UtenButtonType.danger);
      await tester.tap(find.widgetWithText(UtenButton, '取消'));
      await tester.pumpAndSettle();
      expect(
        api.requestedPaths.where((path) => path.endsWith('/reverse')),
        isEmpty,
      );
      await tester.tap(find.widgetWithText(UtenButton, '红冲'));
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(
        api.requestedPaths.where((path) => path.endsWith('/reverse')),
        hasLength(1),
      );
      expect(find.widgetWithText(UtenButton, '红冲'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmed delete blocks early back and still returns after completion',
    (tester) async {
      final gate = Completer<void>();
      final (api, _) = await _pump(
        tester,
        fromWorkshop: true,
        commandGate: gate,
        onApprove: (_) => null,
      );
      await tester.tap(find.widgetWithText(UtenButton, '删除'));
      await tester.pumpAndSettle();
      var confirm = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(UtenButton, '删除'),
      );
      expect(tester.widget<UtenButton>(confirm).type, UtenButtonType.danger);
      await tester.tap(find.widgetWithText(UtenButton, '取消'));
      await tester.pumpAndSettle();
      expect(api.deletions, 0);
      await tester.tap(find.widgetWithText(UtenButton, '删除'));
      await tester.pumpAndSettle();
      confirm = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(UtenButton, '删除'),
      );
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ProductionDailyReportDetailPage), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('已回车间任务'), findsOneWidget);
      expect(api.deletions, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in const [
    Size(375, 844),
    Size(768, 1024),
    Size(1440, 1000),
    Size(844, 390),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'error retry remains reachable at $size with large text, dark=$dark',
        (tester) async {
          final capture =
              Platform.environment['UTEN_CAPTURE_DAILY_REPORT_UI'] == 'true';
          final key = capture ? GlobalKey() : null;
          if (capture) await loadAuditScreenshotFonts(tester);
          final (api, _) = await _pump(
            tester,
            size: size,
            dark: dark,
            textScale: 1.5,
            readFailure: Exception('failed'),
            onApprove: (_) => null,
            captureKey: key,
          );
          final retry = find.widgetWithText(OutlinedButton, '重试');
          await tester.ensureVisible(retry);
          await tester.pumpAndSettle();
          expect(tester.getRect(retry).bottom, lessThanOrEqualTo(size.height));
          expect(tester.takeException(), isNull);
          if (key != null) {
            await saveAuditScreenshot(
              tester,
              key,
              'daily-report-error-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
            );
            api.readFailure = null;
            await tester.tap(retry);
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(UtenButton, '删除'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await saveAuditScreenshot(
              tester,
              key,
              'daily-report-confirm-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
            );
            await tester.tap(find.widgetWithText(UtenButton, '取消'));
            await tester.pumpAndSettle();
            expect(api.deletions, 0);
          }
        },
      );
    }
  }

  testWidgets(
    'workshop review keeps its return destination after editing the draft',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        fromWorkshop: true,
        onApprove: (server) {
          server.serverStatus = 1;
          return null;
        },
      );
      final reads = api.detailReads;
      await tester.tap(find.widgetWithText(UtenButton, '编辑'));
      await tester.pumpAndSettle();
      expect(find.text('保存编辑 workshop-tasks'), findsOneWidget);
      await tester.tap(find.text('保存编辑 workshop-tasks'));
      await tester.pumpAndSettle();
      expect(api.detailReads, reads + 1);
      expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
      await _tapApprove(tester);
      expect(find.text('已回车间任务'), findsOneWidget);
      expect(api.approveKeys, hasLength(1));
    },
  );

  testWidgets(
    'workshop draft without approval capability stays visible and never auto-approves',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        fromWorkshop: true,
        approvable: false,
        onApprove: (_) => null,
      );
      expect(find.byType(ProductionDailyReportDetailPage), findsOneWidget);
      expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
      expect(api.approveKeys, isEmpty);
    },
  );

  for (final responseLost in [false, true]) {
    testWidgets(
      'workshop approval retains unknown command despite approved GET: responseLost=$responseLost',
      (tester) async {
        final (api, _) = await _pump(
          tester,
          fromWorkshop: true,
          onApprove: (server) {
            server.serverStatus = 1;
            return responseLost ? Exception('response lost') : null;
          },
        );
        await _tapApprove(tester);
        expect(
          find.text('已回车间任务'),
          responseLost ? findsNothing : findsOneWidget,
        );
        expect(
          find.byType(ProductionDailyReportDetailPage),
          responseLost ? findsOneWidget : findsNothing,
        );
        expect(api.approveKeys, hasLength(1));
      },
    );
  }

  testWidgets('workshop rejected approval stays on the draft detail', (
    tester,
  ) async {
    await _pump(
      tester,
      fromWorkshop: true,
      onApprove: (_) => ApiException('BUSINESS', 'rejected', httpStatus: 400),
    );
    await _tapApprove(tester);
    expect(find.byType(ProductionDailyReportDetailPage), findsOneWidget);
    expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
  });

  testWidgets('持审核码但服务端不允许(缺车间直送审核权)：不画审核按钮', (tester) async {
    await _pump(tester, onApprove: (server) => null, approvable: false);

    expect(
      find.widgetWithText(UtenButton, '审核'),
      findsNothing,
      reason: '按钮只看服务端下发的 allowedActions，不能让人点了才被拒',
    );
  });

  testWidgets('审核拿到 200：按钮换成红冲，且不再多发一次详情请求', (tester) async {
    final (api, notices) = await _pump(
      tester,
      onApprove: (server) {
        server.serverStatus = 1;
        return null;
      },
    );
    final readsAfterLoad = api.detailReads;
    expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);

    await _tapApprove(tester);

    expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
    expect(find.widgetWithText(UtenButton, '红冲'), findsOneWidget);
    expect(api.detailReads, readsAfterLoad, reason: '成功路径不该再回读详情');
    expect(notices, contains('已审核'));
  });

  testWidgets('审核超时且 GET 已审核：保留原提交待核对，不宣告命令成功', (tester) async {
    final (api, notices) = await _pump(
      tester,
      onApprove: (server) {
        // 事故原样：事务提交了，响应被客户端的建连计时器掐掉。
        server.serverStatus = 1;
        return NetworkTimeoutException();
      },
    );
    final readsAfterLoad = api.detailReads;

    await _tapApprove(tester);

    expect(
      find.widgetWithText(UtenButton, '审核'),
      findsNothing,
      reason: '状态已是已审核，再画审核按钮就是在邀请用户重复提交',
    );
    expect(
      find.byKey(const Key('daily-report-resolve-approval')),
      findsOneWidget,
    );
    expect(api.detailReads, readsAfterLoad + 1, reason: '失败路径必须重读一次');
    expect(
      notices.contains('当前显示已审核，但原提交尚未获得可核对回执。请保留原内容，继续核对原审核。'),
      isTrue,
      reason: '只说明当前状态，不把无法归因的结果说成本次命令成功',
    );
    expect(notices.any((message) => message.contains('本次提交')), isFalse);
    expect(api.approvalStorage.records, hasLength(1));
    expect(
      api.notifications.where((n) => n.kind == AppNotificationKind.success),
      isEmpty,
    );
  });

  testWidgets('货品/颜色/单位/车间/参与人员全用随单下发的名字，不查任何主档字典', (tester) async {
    final (api, _) = await _pump(tester, onApprove: (server) => null);

    expect(find.text('外贸V5多功能三插后座'), findsWidgets);
    expect(find.text('HV50070'), findsWidgets);
    expect(find.text('深灰色'), findsWidgets);
    // 2026-10-10 数量内联口径：单位列撤销，随单下发的单位名内联在数量后。
    expect(find.text('1000 只'), findsWidgets);
    expect(find.text('六车间'), findsOneWidget);
    expect(find.text('王小明'), findsOneWidget);
    expect(
      api.requestedPaths.where((path) => path.contains('/master/')),
      isEmpty,
      reason: '名称随单下发后不该再查货品/颜色/单位字典',
    );
    expect(
      api.requestedPaths.where((path) => path.contains('/org/employees')),
      isEmpty,
      reason: '参与人员姓名随单下发后不该再调员工档案接口',
    );
  });

  testWidgets('旧版未知审核只查询原记录，当前GET推进版本不补版本或换键', (tester) async {
    final (api, _) = await _pump(
      tester,
      // A lost legacy response has no reviewed-version proof to upgrade.
      onApprove: (server) => NetworkTimeoutException(),
    );

    await _tapApprove(tester);
    final before = jsonDecode(api.approvalStorage.records.values.single) as Map;
    api.rowVersion = 7;
    await tester.tap(find.byKey(const Key('daily-report-resolve-approval')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('daily-report-resolve-approval')));
    await tester.pumpAndSettle();

    expect(api.approveKeys, hasLength(1));
    expect(api.approveKeys.first, startsWith('daily-report-approve-'));
    expect(jsonDecode(api.approvalStorage.records.values.single), before);
    expect(before['commandVersion'], 1);
    expect(before.containsKey('expectedVersion'), isFalse);
    expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
    expect(
      find.byKey(const Key('daily-report-retry-original-approval')),
      findsNothing,
    );
  });

  testWidgets('明细显示不良数：列头说明只记录，0 留空不显示', (tester) async {
    await _pump(tester, onApprove: (_) => null);
    final table = tester.widget<MasterDataTableView<ProductionDailyReportItem>>(
      find.byType(MasterDataTableView<ProductionDailyReportItem>),
    );
    final defect = table.columns.singleWhere(
      (column) => column.key == 'defectQty',
    );
    expect(defect.label, '不良数');
    expect(defect.info, productionDailyReportDefectInfo);
    expect(table.items.single.defectQty, 12.5);
    // 2026-10-10 数量内联口径：不良数直接带单位显示。
    expect(find.text('12.5 只'), findsOneWidget);
    expect(defect.value(const ProductionDailyReportItem(id: 'slice')), isNull);
    expect(
      defect.value(
        ProductionDailyReportItem.fromJson(const {'id': 'x', 'defectQty': 3}),
      ),
      '3',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端明确拒绝且状态没变：照常报错，页面不乱改', (tester) async {
    final (api, notices) = await _pump(
      tester,
      onApprove: (server) =>
          ApiException('BUSINESS', '明细为空，不可审核', httpStatus: 400),
    );
    final readsAfterLoad = api.detailReads;

    await _tapApprove(tester);

    expect(find.widgetWithText(UtenButton, '审核'), findsOneWidget);
    expect(find.widgetWithText(UtenButton, '红冲'), findsNothing);
    expect(api.detailReads, readsAfterLoad + 1);
    expect(notices, contains('明细为空，不可审核'));
  });
}
