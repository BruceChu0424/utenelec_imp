import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/pages/notice_list_page.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/widgets/notice_card.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

/// 通知列表页分组改版的页面级契约：
/// - 默认筛选是「未读」（list 请求带 onlyUnread=true）；
/// - 同一业务对象（路由回执 + 服务端聚合卡）叠成一组：组卡带「共 N 条」胶囊，
///   点开弹窗列出全部（未读在前），「全部已读」逐条置读；
/// - 同类系统事件叠放，恢复、异常主题及不同更新版本仍各自独立；
/// - 无业务锚点的公告、庆典和工作待办仍为普通单卡。
class _FakeNoticeRepository implements NoticeRepository {
  _FakeNoticeRepository(this._notices);

  final List<Notice> _notices;
  final List<Map<String, dynamic>> listCalls = [];
  final List<String> markReadCalls = [];
  final Set<String> failReadIds = {};

  @override
  Future<List<Notice>> list({bool? onlyUnread, bool? importantOnly}) async {
    listCalls.add({'onlyUnread': onlyUnread, 'importantOnly': importantOnly});
    return _notices;
  }

  @override
  Future<Notice> markRead(String id) async {
    markReadCalls.add(id);
    if (failReadIds.contains(id)) throw StateError('network unavailable');
    // 真实后端置读后重查即为已读；模拟同口径，让列表失效重拉拿到新状态。
    final index = _notices.indexWhere((n) => n.id == id);
    if (index >= 0) {
      _notices[index] = _notices[index].copyWith(isRead: true);
    }
    return _notices[index];
  }

  @override
  Future<Notice?> getById(String id) async =>
      _notices.where((notice) => notice.id == id).firstOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReceiptRepository extends _FakeNoticeRepository {
  _ReceiptRepository(super.notices);

  final gate = Completer<void>();
  int acknowledgements = 0;

  @override
  Future<List<Notice>> list({bool? onlyUnread, bool? importantOnly}) async =>
      _notices.where((notice) => onlyUnread != true || !notice.isRead).toList();

  @override
  Future<Notice> acknowledge(String id) async {
    acknowledgements++;
    if (acknowledgements == 1) throw StateError('offline');
    await gate.future;
    final index = _notices.indexWhere((notice) => notice.id == id);
    return _notices[index] = _notices[index].copyWith(
      isRead: true,
      myAcked: true,
      ackCount: 1,
    );
  }
}

class _GatedReadRepository extends _FakeNoticeRepository {
  _GatedReadRepository(super.notices);

  final firstRead = Completer<void>();

  @override
  Future<Notice> markRead(String id) async {
    markReadCalls.add(id);
    if (markReadCalls.length == 1) await firstRead.future;
    final index = _notices.indexWhere((notice) => notice.id == id);
    return _notices[index] = _notices[index].copyWith(isRead: true);
  }
}

class _TrackingReceiptRepository extends _FakeNoticeRepository {
  _TrackingReceiptRepository(super.notices);

  final List<String> acknowledgeCalls = [];

  @override
  Future<Notice> acknowledge(String id) async {
    acknowledgeCalls.add(id);
    final index = _notices.indexWhere((notice) => notice.id == id);
    return _notices[index] = _notices[index].copyWith(
      isRead: true,
      myAcked: true,
      ackCount: 1,
    );
  }
}

Notice _systemNotice(
  String id, {
  required String title,
  required String sourceEvent,
  NoticeType type = NoticeType.urgent,
  bool isRead = false,
  int ageInHours = 1,
}) => Notice(
  id: id,
  title: title,
  content: type == NoticeType.urgent
      ? '最近一次检查未通过，请核对备份任务、存储和恢复所需文件。'
      : '请在服务器状态页查看这次通知的详细记录。',
  type: type,
  publisher: '系统监控',
  publishedAt: ChinaDateTime.now().subtract(Duration(hours: ageInHours)),
  isRead: isRead,
  actionRoute: '/admin/server-status',
  sourceEvent: sourceEvent,
  interactionMode: NoticeInteractionMode.acknowledge,
);

List<Notice> _monitoringNotices() => [
  _systemNotice(
    'disk-new',
    title: '本机备份盘未挂载',
    sourceEvent: 'SERVER_HOST_ALERT:11111111-1111-4111-8111-111111111111',
  ),
  _systemNotice(
    'recovered-new',
    title: '【已恢复】备份已回到正常范围',
    sourceEvent: 'SERVER_STATUS_ALERT:backup:RECOVERED',
    type: NoticeType.system,
    ageInHours: 3,
  ),
  _systemNotice(
    'backup-new',
    title: '【危急】备份需要尽快处理',
    sourceEvent: 'SERVER_STATUS_ALERT:backup:CRITICAL',
    ageInHours: 3,
  ),
  _systemNotice(
    'database',
    title: '数据库备份与恢复点检查失败',
    sourceEvent: 'SERVER_HOST_ALERT:22222222-2222-4222-8222-222222222222',
    ageInHours: 3,
  ),
  _systemNotice(
    'disk-old',
    title: '本机备份盘未挂载',
    sourceEvent: 'SERVER_HOST_ALERT:33333333-3333-4333-8333-333333333333',
    ageInHours: 7,
  ),
  _systemNotice(
    'disk-older',
    title: '本机备份盘未挂载',
    sourceEvent: 'SERVER_HOST_ALERT:44444444-4444-4444-8444-444444444444',
    isRead: true,
    ageInHours: 13,
  ),
  _systemNotice(
    'update-new',
    title: '服务器有新版本 v2.5.52',
    sourceEvent: 'SERVER_UPDATE:new-revision',
    type: NoticeType.system,
    ageInHours: 21,
  ),
  _systemNotice(
    'update-old',
    title: '服务器有新版本 v2.5.52',
    sourceEvent: 'SERVER_UPDATE:old-revision',
    type: NoticeType.system,
    isRead: true,
    ageInHours: 22,
  ),
  _systemNotice(
    'recovered-old',
    title: '【已恢复】备份已回到正常范围',
    sourceEvent: 'SERVER_STATUS_ALERT:backup:RECOVERED',
    type: NoticeType.system,
    ageInHours: 24,
  ),
  _systemNotice(
    'backup-old',
    title: '【危急】备份需要尽快处理',
    sourceEvent: 'SERVER_STATUS_ALERT:backup:CRITICAL',
    ageInHours: 24,
  ),
];

const _orderA = '11111111-1111-4111-8111-111111111111';

Notice _notice(
  String id, {
  String? actionRoute,
  String? aggregateKind,
  String? aggregateId,
  bool isRead = false,
  DateTime? publishedAt,
  NoticeType type = NoticeType.workflow,
}) {
  return Notice(
    id: id,
    title: '标题-$id',
    content: '内容',
    type: type,
    publisher: '系统',
    publishedAt: publishedAt ?? DateTime.utc(2026, 10, 9, 12),
    isRead: isRead,
    actionRoute: actionRoute,
    aggregateKind: aggregateKind,
    aggregateId: aggregateId,
  );
}

Future<void> _mount(
  WidgetTester tester,
  NoticeRepository repository, {
  double width = 1400,
  double textScale = 1,
  bool disableAnimations = false,
  bool dark = false,
  bool withRouter = false,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = withRouter
      ? GoRouter(
          initialLocation: '/notice',
          routes: [
            GoRoute(
              path: '/notice',
              builder: (_, state) => const NoticeListPage(),
            ),
            GoRoute(
              path: '/sales/orders/:id',
              builder: (_, state) => const Scaffold(body: Text('订单业务页面')),
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  Widget builder(BuildContext context, Widget? child) => RepaintBoundary(
    key: const ValueKey('notice-preview'),
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: child!,
    ),
  );
  final app = router == null
      ? MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          builder: builder,
          home: const NoticeListPage(),
        )
      : MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          builder: builder,
        );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        noticeRepositoryProvider.overrideWithValue(repository),
        authenticatedScopeProvider.overrideWithValue(null),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid'),
        badgeSummaryProvider.overrideWith(
          () => FixedBadgeSummaryNotifier(badgeSummaryFixture()),
        ),
      ],
      child: app,
    ),
  );
  await tester.pumpAndSettle();
}

void _expectFullTextInsideCard(
  WidgetTester tester,
  Finder textFinder,
  Rect card,
) {
  expect(textFinder, findsOneWidget);
  final text = tester.widget<Text>(textFinder);
  expect(text.overflow, isNot(TextOverflow.ellipsis));
  expect(text.maxLines, isNull);
  final richText = find.descendant(
    of: textFinder,
    matching: find.byType(RichText),
  );
  expect(richText, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  expect(paragraph.didExceedMaxLines, isFalse);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.data!.length),
  );
  expect(boxes, isNotEmpty);
  for (final box in boxes) {
    final topLeft = paragraph.localToGlobal(Offset(box.left, box.top));
    final bottomRight = paragraph.localToGlobal(Offset(box.right, box.bottom));
    expect(card.inflate(0.5).contains(topLeft), isTrue);
    expect(card.inflate(0.5).contains(bottomRight), isTrue);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const previewDirectory = String.fromEnvironment('NOTICE_PREVIEW_DIR');
    if (previewDirectory.isEmpty) return;
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets(
    'received notice leaves unread and stays read after reloading all',
    (tester) async {
      final repository = _ReceiptRepository([
        Notice(
          id: 'receipt',
          title: '服务器有新版本 v2.5.46',
          content: '已手动检查到新版本。请进入服务器运维页核对。',
          type: NoticeType.system,
          publisher: '系统',
          publishedAt: ChinaDateTime.now(),
          isRead: false,
          interactionMode: NoticeInteractionMode.acknowledge,
        ),
      ]);
      await _mount(tester, repository);
      const previewDirectory = String.fromEnvironment('NOTICE_PREVIEW_DIR');
      await _capture(tester, previewDirectory, 'receipt-before.png');

      await tester.tap(find.text('收到'));
      await tester.pumpAndSettle();
      expect(repository.acknowledgements, 1);
      expect(
        find.byKey(const ValueKey('notice-unread-indicator')),
        findsOneWidget,
      );
      expect(find.byType(UtenBusyOverlay), findsNothing);

      await tester.tap(find.text('收到'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('收到'), warnIfMissed: false);
      expect(repository.acknowledgements, 2);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      repository.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(NoticeCard), findsNothing);
      expect(find.byType(UtenBusyOverlay), findsNothing);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(find.text('已收到'), findsOneWidget);
      expect(find.text('服务器有新版本 v2.5.46'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('notice-unread-indicator')),
        findsNothing,
      );
      await _capture(tester, previewDirectory, 'receipt-after.png');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('defaults to unread filter', (tester) async {
    final repository = _FakeNoticeRepository([_notice('a')]);
    await _mount(tester, repository);

    expect(repository.listCalls.first['onlyUnread'], isTrue);
    final segment = tester.widget<UtenFilterToolbar<NoticeFilter>>(
      find.byType(UtenFilterToolbar<NoticeFilter>),
    );
    expect(segment.selected, {NoticeFilter.unread});
  });

  testWidgets('stacks same-object notices with pill and opens group dialog', (
    tester,
  ) async {
    final repository = _FakeNoticeRepository([
      // 同一订单：最新未读回执 + 较早已读的聚合卡 → 叠成一组。
      _notice(
        'receipt',
        actionRoute: '/sales/orders/$_orderA',
        publishedAt: DateTime.utc(2026, 10, 9, 12),
      ),
      _notice(
        'card',
        actionRoute: '/sales/orders/$_orderA',
        aggregateKind: 'SALES_ORDER',
        aggregateId: _orderA,
        isRead: true,
        publishedAt: DateTime.utc(2026, 10, 8, 9),
      ),
      // 无锚点公告：普通单卡。
      _notice('broadcast', type: NoticeType.announcement),
    ]);
    await _mount(tester, repository);

    // 组卡：卡面是未读回执，胶囊显示 2 条 1 未读；公告单卡无胶囊。
    expect(find.textContaining('共 2 条'), findsOneWidget);
    expect(find.text('标题-receipt'), findsOneWidget);
    expect(find.text('标题-broadcast'), findsOneWidget);

    await tester.tap(find.textContaining('共 2 条'));
    await tester.pumpAndSettle();

    // 组弹窗：未读在前 + 全部已读动作（页面在弹窗后面仍挂着，卡面文本会命中两次）。
    expect(find.text('相关通知'), findsOneWidget);
    expect(find.textContaining('未读 1 条'), findsOneWidget);
    expect(find.text('标题-receipt'), findsNWidgets(2));
    expect(find.text('标题-card'), findsOneWidget);

    // 「全部已读」按钮弹窗内外各有一个（页面在弹窗后面仍挂着），点弹窗内那个。
    await tester.tap(find.text('全部已读').last);
    await tester.pumpAndSettle();

    expect(repository.markReadCalls, ['receipt']);
    expect(find.byIcon(Icons.circle), findsNothing);
    // 头部同排计数翻成「全部已读」（弹窗内按钮随未读清零隐藏）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notice-group-stage')),
        matching: find.text('共 2 条 · 全部已读'),
      ),
      findsOneWidget,
    );
  });

  for (final disabled in [false, true]) {
    testWidgets(
      'stack unfolds into separate cards and closes with Escape, reduced=$disabled',
      (tester) async {
        final repository = _FakeNoticeRepository([
          _notice('receipt', actionRoute: '/sales/orders/$_orderA'),
          _notice('card', actionRoute: '/sales/orders/$_orderA'),
        ]);
        await _mount(tester, repository, disableAnimations: disabled);
        await tester.tap(find.textContaining('共 2 条'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));
        final unfolded = find.byKey(const ValueKey('notice-unfold-receipt'));
        final moving = tester
            .widget<Transform>(unfolded)
            .transform
            .getTranslation()
            .y;
        expect(moving, disabled ? 0 : lessThan(0));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Transform>(unfolded).transform.getTranslation().y,
          0,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('notice-group-stage')),
            matching: find.byType(NoticeCard),
          ),
          findsNWidgets(2),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('notice-group-stage')), findsNothing);
        expect(repository.markReadCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'same monitoring subjects stack while recovery and versions stay separate',
    (tester) async {
      final repository = _FakeNoticeRepository([
        ..._monitoringNotices(),
        _systemNotice(
          'update-other-version',
          title: '服务器有新版本 v2.5.53',
          sourceEvent: 'SERVER_UPDATE:next-version',
          type: NoticeType.system,
        ),
      ]);
      await _mount(tester, repository);

      expect(find.byType(NoticeStackCard), findsNWidgets(4));
      expect(find.text('本机备份盘未挂载'), findsOneWidget);
      expect(find.text('【已恢复】备份已回到正常范围'), findsOneWidget);
      expect(find.text('【危急】备份需要尽快处理'), findsOneWidget);
      expect(find.text('服务器有新版本 v2.5.52'), findsOneWidget);
      expect(find.text('服务器有新版本 v2.5.53'), findsOneWidget);
      final disk = find.ancestor(
        of: find.text('本机备份盘未挂载'),
        matching: find.byType(NoticeStackCard),
      );
      expect(
        find.descendant(of: disk, matching: find.text('共 3 条 · 2 未读')),
        findsOneWidget,
      );

      await tester.tap(find.text('本机备份盘未挂载'));
      await tester.pumpAndSettle();
      final stage = find.byKey(const ValueKey('notice-group-stage'));
      expect(
        find.descendant(of: stage, matching: find.byType(NoticeCard)),
        findsNWidgets(3),
      );
      expect(
        find.descendant(of: stage, matching: find.text('【危急】备份需要尽快处理')),
        findsNothing,
      );
      expect(
        find.descendant(of: stage, matching: find.text('【已恢复】备份已回到正常范围')),
        findsNothing,
      );
      expect(repository.markReadCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('receiving one stacked alert preserves every other receipt', (
    tester,
  ) async {
    final repository = _TrackingReceiptRepository([
      _systemNotice(
        'first',
        title: '本机备份盘未挂载',
        sourceEvent: 'SERVER_HOST_ALERT:first',
      ),
      _systemNotice(
        'second',
        title: '本机备份盘未挂载',
        sourceEvent: 'SERVER_HOST_ALERT:second',
        ageInHours: 2,
      ),
    ]);
    await _mount(tester, repository, withRouter: true);
    await tester.tap(find.text('共 2 条 · 2 未读'));
    await tester.pumpAndSettle();
    final firstCard = find.descendant(
      of: find.byKey(const ValueKey('notice-unfold-first')),
      matching: find.byType(NoticeCard),
    );
    await tester.tap(firstCard);
    await tester.pumpAndSettle();
    expect(repository.markReadCalls, ['first']);
    expect(repository.acknowledgeCalls, isEmpty);
    await tester.ensureVisible(find.text('点击收到'));
    await tester.tap(find.text('点击收到'));
    await tester.pumpAndSettle();
    expect(repository.acknowledgeCalls, ['first']);
    expect(
      repository._notices
          .singleWhere((notice) => notice.id == 'second')
          .myAcked,
      isFalse,
    );
    expect(
      repository._notices.singleWhere((notice) => notice.id == 'second').isRead,
      isFalse,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notice-group-stage')), findsOneWidget);
    expect(find.textContaining('未读 1 条'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('共 2 条 · 1 未读'), findsOneWidget);
    expect(repository.markReadCalls, ['first']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid repeated opening and interruption leaves one intact stack',
    (tester) async {
      final repository = _FakeNoticeRepository([
        _systemNotice(
          'first',
          title: '本机备份盘未挂载',
          sourceEvent: 'SERVER_HOST_ALERT:first',
        ),
        _systemNotice(
          'second',
          title: '本机备份盘未挂载',
          sourceEvent: 'SERVER_HOST_ALERT:second',
        ),
      ]);
      await _mount(tester, repository);
      for (var cycle = 0; cycle < 12; cycle++) {
        final stack = find.text('共 2 条 · 2 未读');
        await tester.tap(stack);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(stack, warnIfMissed: false);
        await tester.pumpAndSettle();
        // The second click may land on the backdrop and close the group.
        // Both outcomes must settle without duplicate modal routes.
        final stage = find.byKey(const ValueKey('notice-group-stage'));
        expect(stage.evaluate().length, lessThanOrEqualTo(1));
        if (stage.evaluate().isNotEmpty) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump(const Duration(milliseconds: 60));
          await tester.tap(stack, warnIfMissed: false);
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('notice-group-stage')), findsNothing);
        expect(find.byType(NoticeStackCard), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(repository.markReadCalls, isEmpty);
      expect(repository._notices.map((notice) => notice.id), [
        'first',
        'second',
      ]);
    },
  );

  testWidgets(
    'monitoring card visual review: repeated alerts, recovery and updates',
    (tester) async {
      const previewDirectory = String.fromEnvironment('NOTICE_PREVIEW_DIR');
      await _mount(
        tester,
        _FakeNoticeRepository(_monitoringNotices()),
        width: 1440,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, previewDirectory, 'notice-monitoring-inbox.png');
      await tester.tap(find.text('本机备份盘未挂载'));
      await tester.pumpAndSettle();
      await _capture(
        tester,
        previewDirectory,
        'notice-monitoring-expanded.png',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _mount(
        tester,
        _FakeNoticeRepository(_monitoringNotices()),
        width: 375,
        textScale: 2,
        dark: true,
      );
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        previewDirectory,
        'notice-monitoring-mobile-dark-200.png',
      );
    },
  );

  testWidgets(
    'cancelling batch read drains the current request and retries only unread notices',
    (tester) async {
      final repository = _GatedReadRepository([
        _systemNotice(
          'first',
          title: '本机备份盘未挂载',
          sourceEvent: 'SERVER_HOST_ALERT:first',
        ),
        _systemNotice(
          'second',
          title: '本机备份盘未挂载',
          sourceEvent: 'SERVER_HOST_ALERT:second',
          ageInHours: 2,
        ),
        _systemNotice(
          'third',
          title: '本机备份盘未挂载',
          sourceEvent: 'SERVER_HOST_ALERT:third',
          ageInHours: 3,
        ),
      ]);
      await _mount(tester, repository);
      await tester.tap(find.text('共 3 条 · 3 未读'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部已读').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repository.markReadCalls, ['first']);
      expect(find.text('0 / 3'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await tester.tap(find.byKey(const ValueKey('uten-progress-cancel')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('uten-progress-stopping')),
        findsOneWidget,
      );
      expect(repository.markReadCalls, ['first']);
      // Cancellation keeps the pending write visible until its actual outcome.
      expect(
        find.byKey(const ValueKey('uten-progress-cancel')),
        findsOneWidget,
      );
      repository.firstRead.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('uten-progress-cancel')), findsNothing);
      expect(find.textContaining('未读 2 条'), findsOneWidget);
      expect(repository.markReadCalls, ['first']);
      await tester.tap(find.text('全部已读').last);
      await tester.pumpAndSettle();
      expect(repository.markReadCalls, ['first', 'second', 'third']);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('notice-group-stage')),
          matching: find.text('共 3 条 · 全部已读'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial read failure retains unread state and can retry', (
    tester,
  ) async {
    final repository = _FakeNoticeRepository([
      _notice('receipt', actionRoute: '/sales/orders/$_orderA'),
      _notice('card', actionRoute: '/sales/orders/$_orderA'),
    ])..failReadIds.add('card');
    await _mount(tester, repository);
    await tester.tap(find.textContaining('共 2 条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部已读').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('未读 1 条'), findsOneWidget);
    expect(repository.markReadCalls, ['card', 'receipt']);
    repository.failReadIds.clear();
    await tester.tap(find.text('全部已读').last);
    await tester.pumpAndSettle();
    expect(repository.markReadCalls, ['card', 'receipt', 'card']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notice-group-stage')),
        matching: find.text('共 2 条 · 全部已读'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('business action dismisses detail and the group stage', (
    tester,
  ) async {
    final repository = _FakeNoticeRepository([
      _notice('receipt', actionRoute: '/sales/orders/$_orderA'),
      _notice('card', actionRoute: '/sales/orders/$_orderA'),
    ]);
    await _mount(tester, repository, withRouter: true);
    await tester.tap(find.textContaining('共 2 条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题-card').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看详情').last);
    await tester.tap(find.text('查看详情').last);
    await tester.pumpAndSettle();
    expect(find.text('订单业务页面'), findsOneWidget);
    expect(find.byKey(const ValueKey('notice-group-stage')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notification visual review: types, stack and expanded stage', (
    tester,
  ) async {
    const previewDirectory = String.fromEnvironment('NOTICE_PREVIEW_DIR');
    final now = ChinaDateTime.now();
    final notices = <Notice>[
      for (var i = 0; i < NoticeType.values.length; i++)
        Notice(
          id: 'visual-$i',
          title: const [
            '十月员工关怀与调休安排',
            '新版差旅报销制度开始执行',
            '本月生日礼遇已送达',
            '系统维护窗口提醒',
            '请及时核对异常出库记录',
            '采购交期确认待处理',
            '订单财务审核已通过',
            '订单 SO20261028 已完成入库',
            '一起祝陈晓生日快乐',
            '感谢王敏与优腾同行五周年',
            '把祝福送给新婚的同事',
            '欢迎同事家里的新成员',
          ][i],
          content: const [
            '请同事们查阅最新安排，并在通知详情中点击收到。',
            '审批、交期与生产节点集中在这里，每一步进展都有记录。',
          ][i % 2],
          type: NoticeType.values[i],
          publisher: i < 3 || i > 7 ? '行政与人力资源部' : '业务协同中心',
          publishedAt: now.subtract(Duration(minutes: 20 + i * 12)),
          isRead: false,
          priority: i == 0 ? NoticePriority.important : NoticePriority.normal,
          actionRoute: i == 7 ? '/sales/orders/$_orderA' : null,
        ),
      Notice(
        id: 'visual-related',
        title: '订单 SO20261028 生产报工完成',
        content: '成品已进入入库流程，可查看订单最新进展。',
        type: NoticeType.task,
        publisher: '生产部',
        publishedAt: now.subtract(const Duration(hours: 3)),
        isRead: false,
        actionRoute: '/sales/orders/$_orderA',
      ),
    ];
    await _mount(tester, _FakeNoticeRepository(notices));
    expect(find.byType(NoticeStackCard), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, previewDirectory, 'notice-inbox.png');
    await tester.tap(find.textContaining('共 2 条'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await _capture(tester, previewDirectory, 'notice-unfold-mid.png');
    await tester.pumpAndSettle();
    await _capture(tester, previewDirectory, 'notice-expanded.png');
    await tester.tap(find.byTooltip('收起相关通知'));
    await tester.pumpAndSettle();
    await _mount(
      tester,
      _FakeNoticeRepository(notices),
      width: 375,
      textScale: 2,
      dark: true,
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, previewDirectory, 'notice-mobile-dark-200.png');
  });

  for (final scenario in [
    (width: 1400.0, scale: 1.0, age: const Duration(days: 6, hours: 23)),
    (width: 1400.0, scale: 1.0, age: const Duration(days: 7, hours: 1)),
    (width: 375.0, scale: 1.0, age: const Duration(days: 400)),
    (width: 1400.0, scale: 2.0, age: const Duration(days: 400)),
    (width: 375.0, scale: 2.0, age: const Duration(days: 400)),
  ]) {
    testWidgets('group metadata remains complete at ${scenario.width}px '
        '${scenario.scale}x after ${scenario.age.inDays} days', (tester) async {
      final published = ChinaDateTime.now().subtract(scenario.age);
      final label = scenario.age.inDays < 7
          ? '${scenario.age.inDays} 天前'
          : '${published.year}-${published.month.toString().padLeft(2, '0')}-'
                '${published.day.toString().padLeft(2, '0')}(北京)';
      final repository = _FakeNoticeRepository([
        _notice(
          'receipt',
          actionRoute: '/sales/orders/$_orderA',
          publishedAt: published,
        ),
        _notice(
          'card',
          actionRoute: '/sales/orders/$_orderA',
          publishedAt: published.subtract(const Duration(hours: 1)),
        ),
      ]);
      await _mount(
        tester,
        repository,
        width: scenario.width,
        textScale: scenario.scale,
      );

      expect(tester.takeException(), isNull);
      // 2026-11-10：卡面本体是 NoticeCard（统一表面与叠放计数），
      // 以它为边界校验元数据文本完整落在卡内。
      final card = tester.getRect(
        find.ancestor(
          of: find.text('标题-receipt'),
          matching: find.byType(NoticeCard),
        ),
      );
      _expectFullTextInsideCard(tester, find.text(label), card);
      final count = find.text('共 2 条 · 2 未读');
      _expectFullTextInsideCard(tester, count, card);
      await tester.tap(count);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('相关通知'), findsOneWidget);
      expect(find.text('标题-receipt'), findsNWidgets(2));
      expect(find.text('标题-card'), findsOneWidget);
    });
  }
}

Future<void> _capture(
  WidgetTester tester,
  String directory,
  String filename,
) async {
  if (directory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('notice-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$filename',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
