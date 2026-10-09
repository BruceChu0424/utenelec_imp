import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_segmented_filter.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/pages/notice_list_page.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

/// 通知列表页分组改版的页面级契约：
/// - 默认筛选是「未读」（list 请求带 onlyUnread=true）；
/// - 同一业务对象（路由回执 + 服务端聚合卡）叠成一组：组卡带「共 N 条」胶囊，
///   点开弹窗列出全部（未读在前），「全部已读」逐条置读；
/// - 无锚点的通知仍是普通单卡（无胶囊）。
class _FakeNoticeRepository implements NoticeRepository {
  _FakeNoticeRepository(this._notices);

  final List<Notice> _notices;
  final List<Map<String, dynamic>> listCalls = [];
  final List<String> markReadCalls = [];

  @override
  Future<List<Notice>> list({bool? onlyUnread, bool? importantOnly}) async {
    listCalls.add({'onlyUnread': onlyUnread, 'importantOnly': importantOnly});
    return _notices;
  }

  @override
  Future<Notice> markRead(String id) async {
    markReadCalls.add(id);
    // 真实后端置读后重查即为已读；模拟同口径，让列表失效重拉拿到新状态。
    final index = _notices.indexWhere((n) => n.id == id);
    if (index >= 0) {
      _notices[index] = _notices[index].copyWith(isRead: true);
    }
    return _notices[index];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    publishedAt: publishedAt ?? DateTime(2026, 10, 9, 12),
    isRead: isRead,
    actionRoute: actionRoute,
    aggregateKind: aggregateKind,
    aggregateId: aggregateId,
  );
}

Future<void> _mount(WidgetTester tester, NoticeRepository repository) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
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
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NoticeListPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('defaults to unread filter', (tester) async {
    final repository = _FakeNoticeRepository([_notice('a')]);
    await _mount(tester, repository);

    expect(repository.listCalls.first['onlyUnread'], isTrue);
    final segment = tester.widget<UtenSegmentedFilter<NoticeFilter>>(
      find.byType(UtenSegmentedFilter<NoticeFilter>),
    );
    expect(segment.selected, NoticeFilter.unread);
  });

  testWidgets('stacks same-object notices with pill and opens group dialog', (
    tester,
  ) async {
    final repository = _FakeNoticeRepository([
      // 同一订单：最新未读回执 + 较早已读的聚合卡 → 叠成一组。
      _notice(
        'receipt',
        actionRoute: '/sales/orders/$_orderA',
        publishedAt: DateTime(2026, 10, 9, 12),
      ),
      _notice(
        'card',
        actionRoute: '/sales/orders/$_orderA',
        aggregateKind: 'SALES_ORDER',
        aggregateId: _orderA,
        isRead: true,
        publishedAt: DateTime(2026, 10, 8, 9),
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
    // 头部副标题翻成「全部已读」（弹窗内按钮随未读清零隐藏）。
    expect(find.textContaining('全部已读，未读排在前面'), findsOneWidget);
  });
}
