import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/ui/uten_top_banner_card.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_arrival.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';

void main() {
  testWidgets(
    'persisted cursor dispatches each later id exactly once across identities',
    (tester) async {
      var feed = <Notice>[_notice('old', minute: 1)];
      final store = _MemoryCursorStore()
        ..values['user-a'] = _cursorOf(feed.single)
        ..deliveredValues['user-a'] = <String>{feed.single.id};
      final arrived = <String>[];
      var refreshes = 0;

      NoticeArrivalPage load(NoticeArrivalCursor? after) =>
          _pageFromFeed(feed, after ?? _epochCursor());

      Widget app(String identity) {
        return ProviderScope(
          overrides: [
            noticeArrivalLoaderProvider.overrideWithValue(
              (after) async => load(after),
            ),
            noticeArrivalCursorStoreProvider.overrideWithValue(store),
            noticeArrivalRefreshProvider.overrideWithValue(() async {
              refreshes++;
            }),
          ],
          child: MaterialApp(
            home: NoticeArrivalListener(
              identityKey: identity,
              pollInterval: const Duration(milliseconds: 20),
              onArrival: (_, notice, onDelivered) {
                arrived.add(notice.id);
                onDelivered();
              },
              child: const Text('员工主壳层'),
            ),
          ),
        );
      }

      await tester.pumpWidget(app('user-a'));
      await tester.pump();
      expect(arrived, isEmpty);

      feed = <Notice>[_notice('new-a', minute: 2), _notice('old', minute: 1)];
      await tester.pump(const Duration(milliseconds: 25));
      await tester.pump();
      expect(arrived, <String>['new-a']);
      expect(refreshes, 1);

      await tester.pump(const Duration(milliseconds: 25));
      await tester.pump();
      expect(arrived, <String>['new-a'], reason: '重复轮询不能重复派发同一 ID');

      store.values['user-b'] = _cursorOf(feed.first);
      store.deliveredValues['user-b'] = <String>{'old', 'new-a'};
      await tester.pumpWidget(app('user-b'));
      await tester.pump();
      expect(arrived, <String>['new-a']);

      feed = <Notice>[
        _notice('new-b', minute: 3),
        _notice('new-a', minute: 2),
        _notice('old', minute: 1),
      ];
      await tester.pump(const Duration(milliseconds: 25));
      await tester.pump();
      expect(arrived, <String>['new-a', 'new-b']);
      expect(refreshes, 2);
      expect(store.values['user-b']?.id, 'new-b');
    },
  );

  testWidgets('periodic full audit recovers a late commit behind cursor', (
    tester,
  ) async {
    final late = _notice('late-behind', minute: 1);
    final current = _notice('current-high-water', minute: 2);
    final store = _MemoryCursorStore()
      ..values['buyer'] = _cursorOf(current)
      ..deliveredValues['buyer'] = <String>{current.id};
    final arrived = <String>[];
    final feed = <Notice>[current];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalLoaderProvider.overrideWithValue(
            (after) async => _pageFromFeed(
              feed,
              after ??
                  NoticeArrivalCursor(
                    publishedAt: DateTime.fromMillisecondsSinceEpoch(
                      0,
                      isUtc: true,
                    ),
                    id: NoticeArrivalCursor.zeroId,
                  ),
            ),
          ),
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
        ],
        child: MaterialApp(
          home: NoticeArrivalListener(
            identityKey: 'buyer',
            pollInterval: const Duration(milliseconds: 20),
            fullAuditInterval: const Duration(milliseconds: 40),
            onArrival: (_, notice, onDelivered) {
              arrived.add(notice.id);
              onDelivered();
            },
            child: const Text('员工主壳层'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(arrived, isEmpty);
    feed.insert(0, late);

    await tester.pump(const Duration(milliseconds: 65));
    await tester.pump();
    expect(arrived, <String>['late-behind']);
    expect(store.values['buyer']?.id, current.id);
    expect(store.deliveredValues['buyer'], <String>{late.id, current.id});
  });

  testWidgets(
    'first use replays all unread arrivals and skips already-read items',
    (tester) async {
      final recent = Notice(
        id: 'recent',
        title: '刚到采购通知',
        content: '请处理采购申请',
        type: NoticeType.task,
        publisher: '系统',
        publishedAt: DateTime.now().toUtc().subtract(
          const Duration(minutes: 1),
        ),
        isRead: false,
      );
      final alreadyRead = Notice(
        id: 'already-read',
        title: '另一标签页已读',
        content: '不应再次弹出',
        type: NoticeType.task,
        publisher: '系统',
        publishedAt: recent.publishedAt.add(const Duration(seconds: 30)),
        isRead: true,
      );
      final old = Notice(
        id: 'too-old',
        title: '旧通知',
        content: '旧内容',
        type: NoticeType.task,
        publisher: '系统',
        publishedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
        isRead: false,
      );
      final store = _MemoryCursorStore();
      final arrived = <String>[];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            noticeArrivalLoaderProvider.overrideWithValue(
              (after) async => _pageFromFeed(
                <Notice>[alreadyRead, recent, old],
                after ??
                    NoticeArrivalCursor(
                      publishedAt: DateTime.fromMillisecondsSinceEpoch(
                        0,
                        isUtc: true,
                      ),
                      id: NoticeArrivalCursor.zeroId,
                    ),
              ),
            ),
            noticeArrivalCursorStoreProvider.overrideWithValue(store),
            noticeArrivalRefreshProvider.overrideWithValue(() async {}),
          ],
          child: MaterialApp(
            home: NoticeArrivalListener(
              identityKey: 'first-user',
              pollInterval: const Duration(hours: 1),
              onArrival: (_, notice, onDelivered) {
                arrived.add(notice.id);
                onDelivered();
              },
              child: const Text('员工主壳层'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(arrived, <String>['too-old', 'recent']);
      expect(store.values['first-user']?.id, 'already-read');
    },
  );

  testWidgets('listener drains 101 arrivals across cursor pages in order', (
    tester,
  ) async {
    final base = NoticeArrivalCursor(
      publishedAt: DateTime.utc(2026, 8, 22, 1),
      id: 'base',
    );
    final feed = List<Notice>.generate(101, (index) {
      final id = 'item-${index.toString().padLeft(3, '0')}';
      return Notice(
        id: id,
        title: '通知 $id',
        content: '正文 $id',
        type: NoticeType.task,
        publisher: '系统',
        publishedAt: base.publishedAt.add(Duration(seconds: index + 1)),
        isRead: false,
      );
    });
    final store = _MemoryCursorStore()..values['buyer'] = base;
    final arrived = <String>[];
    var calls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalLoaderProvider.overrideWithValue((after) async {
            calls++;
            return _pageFromFeed(feed, after ?? _epochCursor());
          }),
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
        ],
        child: MaterialApp(
          home: NoticeArrivalListener(
            identityKey: 'buyer',
            pollInterval: const Duration(hours: 1),
            onArrival: (_, notice, onDelivered) {
              arrived.add(notice.id);
              onDelivered();
            },
            child: const Text('员工主壳层'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(calls, 2);
    expect(arrived, hasLength(101));
    expect(arrived.first, 'item-000');
    expect(arrived.last, 'item-100');
    expect(store.values['buyer']?.id, 'item-100');
  });

  testWidgets('online feed reaches the real host strictly one at a time', (
    tester,
  ) async {
    final base = _notice('00000000-0000-0000-0000-000000000201', minute: 1);
    final first = _notice('00000000-0000-0000-0000-000000000202', minute: 2);
    final second = _notice('00000000-0000-0000-0000-000000000203', minute: 3);
    final feed = <Notice>[second, first, base];
    final store = _MemoryCursorStore()
      ..values['buyer'] = _cursorOf(base)
      ..deliveredValues['buyer'] = <String>{base.id};
    final navigatorKey = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: navigatorKey,
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('首页')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalLoaderProvider.overrideWithValue(
            (after) async => _pageFromFeed(feed, after ?? _epochCursor()),
          ),
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => Stack(
            children: [
              NoticeArrivalListener(
                identityKey: 'buyer',
                pollInterval: const Duration(hours: 1),
                routeContext: () => navigatorKey.currentContext,
                child: child!,
              ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(first.title), findsOneWidget);
    expect(find.text(second.title), findsNothing);
    expect(find.byType(UtenTopBannerCard), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text(first.title), findsNothing);
    expect(find.text(second.title), findsOneWidget);
    expect(find.byType(UtenTopBannerCard), findsOneWidget);
    expect(store.deliveredValues['buyer'], contains(first.id));
    expect(store.deliveredValues['buyer'], isNot(contains(second.id)));
  });

  testWidgets(
    'restart mid-queue replays only unplayed items and a later restart is quiet',
    (tester) async {
      final first = _notice('00000000-0000-0000-0000-000000000301', minute: 1);
      final second = _notice('00000000-0000-0000-0000-000000000302', minute: 2);
      final third = _notice('00000000-0000-0000-0000-000000000303', minute: 3);
      final feed = <Notice>[third, second, first];
      final store = _MemoryCursorStore();

      ({Widget widget, GoRouter router}) run(int number) {
        final navigatorKey = GlobalKey<NavigatorState>();
        final router = GoRouter(
          navigatorKey: navigatorKey,
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('首页')),
            ),
          ],
        );
        return (
          router: router,
          widget: ProviderScope(
            key: ValueKey('arrival-run-$number'),
            overrides: [
              noticeArrivalLoaderProvider.overrideWithValue(
                (after) async => _pageFromFeed(feed, after ?? _epochCursor()),
              ),
              noticeArrivalCursorStoreProvider.overrideWithValue(store),
              noticeArrivalRefreshProvider.overrideWithValue(() async {}),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              builder: (context, child) => Stack(
                children: [
                  NoticeArrivalListener(
                    identityKey: 'buyer',
                    pollInterval: const Duration(hours: 1),
                    routeContext: () => navigatorKey.currentContext,
                    child: child!,
                  ),
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: AppNotificationHost(),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      final firstRun = run(1);
      await tester.pumpWidget(firstRun.widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(first.title), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text(second.title), findsOneWidget);
      expect(store.deliveredValues['buyer'], <String>{first.id});

      // 第二条已经进入宿主但尚未关闭；销毁整棵 app 不得把它误记 delivered。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      firstRun.router.dispose();
      expect(store.deliveredValues['buyer'], <String>{first.id});

      final secondRun = run(2);
      await tester.pumpWidget(secondRun.widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(second.title), findsOneWidget);
      expect(find.text(third.title), findsNothing);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text(third.title), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(UtenTopBannerCard), findsNothing);
      expect(store.deliveredValues['buyer'], <String>{
        first.id,
        second.id,
        third.id,
      });

      await tester.pumpWidget(const SizedBox.shrink());
      secondRun.router.dispose();
      final thirdRun = run(3);
      await tester.pumpWidget(thirdRun.widget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(UtenTopBannerCard), findsNothing);
      thirdRun.router.dispose();
    },
  );

  testWidgets('stable empty polls do not rewrite the cursor store', (
    tester,
  ) async {
    final old = _notice('00000000-0000-0000-0000-000000000401', minute: 1);
    final store = _MemoryCursorStore()
      ..values['buyer'] = _cursorOf(old)
      ..deliveredValues['buyer'] = <String>{old.id};
    var loads = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalLoaderProvider.overrideWithValue((after) async {
            loads++;
            return _pageFromFeed(<Notice>[old], after ?? _epochCursor());
          }),
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
        ],
        child: const MaterialApp(
          home: NoticeArrivalListener(
            identityKey: 'buyer',
            pollInterval: Duration(milliseconds: 20),
            child: Text('员工主壳层'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));

    expect(loads, greaterThan(2));
    expect(store.writeCalls, 0);
  });

  testWidgets(
    'important arrival keeps a center alert until explicit close and close only popup-acks',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final requests = <RequestOptions>[];
      final notices = <String, Notice>{};
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            Object data = <String, dynamic>{};
            if (request.method == 'GET' &&
                request.path.startsWith('/notices/') &&
                !request.path.endsWith('/unread-count')) {
              final id = request.path.split('/').last;
              final notice = notices[id];
              if (notice != null) data = _noticeJson(notice);
            } else if (request.path == '/notices/unread-count') {
              data = <String, dynamic>{'count': 0};
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
      final repository = DioNoticeRepository(ApiClient(dio));
      final container = ProviderContainer(
        overrides: [
          noticeRepositoryProvider.overrideWithValue(repository),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      late BuildContext dispatchContext;
      var delivered = 0;
      var opens = 0;
      final rejected = Notice(
        id: '00000000-0000-0000-0000-000000000501',
        title: '订单被财务驳回：SO-001',
        content: '销售订货单 SO-001 未通过财务确认。驳回原因：金额有误。请修改后重新提交。',
        type: NoticeType.approval,
        publisher: '财务部',
        publishedAt: DateTime.utc(2026, 8, 22, 1, 3),
        isRead: false,
        priority: NoticePriority.important,
        sourceEvent: 'SALES_ORDER_FINANCE_REJECTED',
        actionRoute: '/sales/orders/order-1',
      );
      notices[rejected.id] = rejected;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Stack(
              children: [
                Builder(
                  builder: (context) {
                    dispatchContext = context;
                    return const Scaffold(body: Text('首页'));
                  },
                ),
                const Align(
                  alignment: Alignment.topCenter,
                  child: AppNotificationHost(),
                ),
              ],
            ),
          ),
        ),
      );

      dispatchNoticeArrival(
        dispatchContext,
        rejected,
        onOpenDetail: () => opens++,
        onDelivered: () => delivered++,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(UtenTopBannerCard), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('原因'), findsOneWidget);
      expect(find.text('金额有误'), findsOneWidget);
      expect(find.text('查看订单并修改'), findsOneWidget);

      await tester.pump(const Duration(seconds: 30));
      expect(find.byType(Dialog), findsOneWidget);
      expect(delivered, 0);

      await tester.tapAt(const Offset(5, 595));
      await tester.pump();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(Dialog), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(delivered, 1);
      expect(opens, 0);
      expect(
        requests.any(
          (request) =>
              request.method == 'POST' &&
              request.path == '/notices/${rejected.id}/popup-ack',
        ),
        isTrue,
      );
      expect(
        requests.any(
          (request) =>
              request.method == 'POST' &&
              request.path == '/notices/${rejected.id}/read',
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'important primary action popup-acks, marks read, and opens once',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final requests = <RequestOptions>[];
      late Notice rejected;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final data =
                request.method == 'GET' &&
                    request.path == '/notices/${rejected.id}'
                ? _noticeJson(rejected)
                : request.path == '/notices/unread-count'
                ? <String, dynamic>{'count': 0}
                : <String, dynamic>{};
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          noticeRepositoryProvider.overrideWithValue(
            DioNoticeRepository(ApiClient(dio)),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      late BuildContext dispatchContext;
      var delivered = 0;
      var opens = 0;
      rejected = Notice(
        id: '00000000-0000-0000-0000-000000000502',
        title: '订单被财务驳回：SO-002',
        content: '销售订货单 SO-002 未通过财务确认。驳回原因：币种错误。',
        type: NoticeType.approval,
        publisher: '财务部',
        publishedAt: DateTime.utc(2026, 8, 22, 1, 4),
        isRead: false,
        priority: NoticePriority.urgent,
        sourceEvent: 'SALES_ORDER_FINANCE_REJECTED',
        actionRoute: '/sales/orders/order-2',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                dispatchContext = context;
                return const Scaffold(body: Text('首页'));
              },
            ),
          ),
        ),
      );
      dispatchNoticeArrival(
        dispatchContext,
        rejected,
        onOpenDetail: () => opens++,
        onDelivered: () => delivered++,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看订单并修改'));
      await tester.pumpAndSettle();

      expect(opens, 1);
      expect(delivered, 1);
      expect(
        requests.where(
          (request) =>
              request.method == 'POST' &&
              request.path == '/notices/${rejected.id}/popup-ack',
        ),
        hasLength(1),
      );
      expect(
        requests.where(
          (request) =>
              request.method == 'POST' &&
              request.path == '/notices/${rejected.id}/read',
        ),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets(
    'session interruption removes the exact strong alert without popup ack',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          noticeRepositoryProvider.overrideWithValue(
            DioNoticeRepository(ApiClient(dio)),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      final interruptSignal = ValueNotifier<int>(0);
      late BuildContext dispatchContext;
      var delivered = 0;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                dispatchContext = context;
                return const Scaffold(body: Text('首页'));
              },
            ),
          ),
        ),
      );
      final notice = _notice(
        '00000000-0000-0000-0000-000000000503',
        minute: 5,
        priority: NoticePriority.urgent,
      );
      dispatchNoticeArrival(
        dispatchContext,
        notice,
        interruptSignal: interruptSignal,
        onOpenDetail: () {},
        onDelivered: () => delivered++,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Dialog), findsOneWidget);

      interruptSignal.value++;
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(delivered, 0);
      expect(
        requests.where(
          (request) => request.path == '/notices/${notice.id}/popup-ack',
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      interruptSignal.dispose();
      container.dispose();
    },
  );

  testWidgets(
    'listener presents urgent before important and keeps one center window at a time',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final base = _notice('00000000-0000-0000-0000-000000000511', minute: 1);
      final first = _notice(
        '00000000-0000-0000-0000-000000000512',
        minute: 2,
        priority: NoticePriority.important,
      );
      final second = _notice(
        '00000000-0000-0000-0000-000000000513',
        minute: 3,
        priority: NoticePriority.urgent,
      );
      final feed = <Notice>[second, first, base];
      final store = _MemoryCursorStore()
        ..values['buyer'] = _cursorOf(base)
        ..deliveredValues['buyer'] = <String>{base.id};
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: <String, dynamic>{},
            ),
          ),
        ),
      );
      final navigatorKey = GlobalKey<NavigatorState>();
      final router = GoRouter(
        navigatorKey: navigatorKey,
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('首页')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            noticeArrivalLoaderProvider.overrideWithValue(
              (after) async => _pageFromFeed(feed, after ?? _epochCursor()),
            ),
            noticeArrivalCursorStoreProvider.overrideWithValue(store),
            noticeArrivalRefreshProvider.overrideWithValue(() async {}),
            noticeRepositoryProvider.overrideWithValue(
              DioNoticeRepository(ApiClient(dio)),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => Stack(
              children: [
                NoticeArrivalListener(
                  identityKey: 'buyer',
                  pollInterval: const Duration(hours: 1),
                  routeContext: () => navigatorKey.currentContext,
                  child: child!,
                ),
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AppNotificationHost(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(Dialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(second.title),
        ),
        findsOneWidget,
      );
      expect(find.text(first.title), findsNothing);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(first.title),
        ),
        findsOneWidget,
      );
      expect(store.deliveredValues['buyer'], contains(second.id));
      expect(store.deliveredValues['buyer'], isNot(contains(first.id)));

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(
        store.deliveredValues['buyer'],
        containsAll(<String>[first.id, second.id]),
      );
    },
  );

  testWidgets('periodic ticks keep only one arrival request in flight', (
    tester,
  ) async {
    final base = NoticeArrivalCursor(
      publishedAt: DateTime.utc(2026, 8, 22, 1),
      id: 'base',
    );
    final store = _MemoryCursorStore()..values['buyer'] = base;
    final requests = <Completer<NoticeArrivalPage>>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalLoaderProvider.overrideWithValue((_) {
            final request = Completer<NoticeArrivalPage>();
            requests.add(request);
            return request.future;
          }),
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
        ],
        child: const MaterialApp(
          home: NoticeArrivalListener(
            identityKey: 'buyer',
            pollInterval: Duration(milliseconds: 20),
            child: Text('员工主壳层'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(requests, hasLength(1));

    requests[0].complete(
      NoticeArrivalPage(items: const <Notice>[], cursor: base, hasMore: false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));
    expect(requests, hasLength(2));
    requests[1].complete(
      NoticeArrivalPage(items: const <Notice>[], cursor: base, hasMore: false),
    );
    await tester.pump();
  });

  testWidgets('late user A response cannot cancel or dispatch user B request', (
    tester,
  ) async {
    final base = NoticeArrivalCursor(
      publishedAt: DateTime.utc(2026, 8, 22, 1),
      id: 'base',
    );
    final aNotice = _notice('a-new', minute: 1);
    final bNotice = _notice('b-new', minute: 2);
    final store = _MemoryCursorStore()
      ..values['user-a'] = base
      ..values['user-b'] = base;
    final requests = <Completer<NoticeArrivalPage>>[];
    final arrived = <String>[];
    Future<NoticeArrivalPage> loader(NoticeArrivalCursor? _) {
      final request = Completer<NoticeArrivalPage>();
      requests.add(request);
      return request.future;
    }

    Widget app(String identity) => ProviderScope(
      overrides: [
        noticeArrivalLoaderProvider.overrideWithValue(loader),
        noticeArrivalCursorStoreProvider.overrideWithValue(store),
        noticeArrivalRefreshProvider.overrideWithValue(() async {}),
      ],
      child: MaterialApp(
        home: NoticeArrivalListener(
          identityKey: identity,
          pollInterval: const Duration(hours: 1),
          onArrival: (_, notice, onDelivered) {
            arrived.add(notice.id);
            onDelivered();
          },
          child: const Text('员工主壳层'),
        ),
      ),
    );

    await tester.pumpWidget(app('user-a'));
    await tester.pump();
    expect(requests, hasLength(1));
    await tester.pumpWidget(app('user-b'));
    await tester.pump();
    expect(requests, hasLength(2));

    requests[0].complete(
      NoticeArrivalPage(
        items: <Notice>[aNotice],
        cursor: _cursorOf(aNotice),
        hasMore: false,
      ),
    );
    await tester.pump();
    expect(arrived, isEmpty);

    requests[1].complete(
      NoticeArrivalPage(
        items: <Notice>[bNotice],
        cursor: _cursorOf(bNotice),
        hasMore: false,
      ),
    );
    await tester.pump();
    expect(arrived, <String>['b-new']);
  });

  testWidgets('loader completion after listener dispose is ignored', (
    tester,
  ) async {
    final base = NoticeArrivalCursor(
      publishedAt: DateTime.utc(2026, 8, 22, 1),
      id: 'base',
    );
    final store = _MemoryCursorStore()..values['user-a'] = base;
    final request = Completer<NoticeArrivalPage>();
    final arrived = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalLoaderProvider.overrideWithValue((_) => request.future),
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
        ],
        child: MaterialApp(
          home: NoticeArrivalListener(
            identityKey: 'user-a',
            pollInterval: const Duration(hours: 1),
            onArrival: (_, notice, onDelivered) {
              arrived.add(notice.id);
              onDelivered();
            },
            child: const Text('员工主壳层'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    final late = _notice('late', minute: 1);
    request.complete(
      NoticeArrivalPage(
        items: <Notice>[late],
        cursor: _cursorOf(late),
        hasMore: false,
      ),
    );
    await tester.pump();
    expect(arrived, isEmpty);
  });

  testWidgets(
    'default click marks read, routes, and falls back on invalid path',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final valid = Notice(
        id: '00000000-0000-0000-0000-000000000101',
        title: '打开采购申请',
        content: '采购申请待处理',
        type: NoticeType.task,
        publisher: '系统',
        publishedAt: DateTime.utc(2026, 8, 22, 1),
        isRead: false,
        actionRoute: '/target',
      );
      final invalid = Notice(
        id: '00000000-0000-0000-0000-000000000102',
        title: '无效路由通知',
        content: '应回退通知详情',
        type: NoticeType.task,
        publisher: '系统',
        publishedAt: DateTime.utc(2026, 8, 22, 1, 1),
        isRead: false,
        actionRoute: '/missing-target',
      );
      final notices = <String, Notice>{valid.id: valid, invalid.id: invalid};
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            Object data = <String, dynamic>{};
            if (request.path == '/notices/unread-count') {
              data = <String, dynamic>{'count': 0};
            } else if (request.path.startsWith('/notices/') &&
                !request.path.endsWith('/read')) {
              final id = request.path.split('/').last;
              data = _noticeJson(notices[id]!);
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
      final repository = DioNoticeRepository(ApiClient(dio));
      late BuildContext routeContext;
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, _) {
              routeContext = context;
              return const Scaffold(body: Text('首页'));
            },
          ),
          GoRoute(
            path: '/target',
            builder: (_, _) => const Scaffold(body: Text('采购申请详情')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            noticeRepositoryProvider.overrideWithValue(repository),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => Stack(
              children: [
                Positioned.fill(child: child!),
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AppNotificationHost(),
                ),
              ],
            ),
          ),
        ),
      );

      dispatchNoticeArrival(routeContext, valid);
      await tester.pump();
      await tester.tap(find.text(valid.title));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/target');
      expect(
        router.routeInformationProvider.value.uri.queryParameters['returnTo'],
        '/notice',
      );
      expect(
        requests.any(
          (request) =>
              request.method == 'POST' &&
              request.path == '/notices/${valid.id}/read',
        ),
        isTrue,
      );

      router.go('/home');
      await tester.pumpAndSettle();
      dispatchNoticeArrival(routeContext, invalid);
      await tester.pump();
      await tester.tap(find.text(invalid.title));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/home');
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text(invalid.content), findsOneWidget);
    },
  );

  testWidgets('paused response is ignored and resume catches the arrival', (
    tester,
  ) async {
    final requests = <Completer<NoticeArrivalPage>>[];
    final old = _notice('old', minute: 1);
    final fresh = _notice('new', minute: 2);
    final store = _MemoryCursorStore()..values['user-a'] = _cursorOf(old);
    final arrived = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalLoaderProvider.overrideWithValue((_) {
            final request = Completer<NoticeArrivalPage>();
            requests.add(request);
            return request.future;
          }),
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
        ],
        child: MaterialApp(
          home: NoticeArrivalListener(
            identityKey: 'user-a',
            pollInterval: const Duration(milliseconds: 20),
            onArrival: (_, notice, onDelivered) {
              arrived.add(notice.id);
              onDelivered();
            },
            child: const Text('员工主壳层'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(requests, hasLength(1));
    requests[0].complete(
      NoticeArrivalPage(
        items: const <Notice>[],
        cursor: _cursorOf(old),
        hasMore: false,
      ),
    );
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 25));
    expect(requests, hasLength(2));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    requests[1].complete(
      NoticeArrivalPage(
        items: <Notice>[fresh],
        cursor: _cursorOf(fresh),
        hasMore: false,
      ),
    );
    await tester.pump();
    expect(arrived, isEmpty, reason: '暂停后的迟到响应不能直接弹条');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(requests, hasLength(3));
    requests[2].complete(
      NoticeArrivalPage(
        items: <Notice>[fresh],
        cursor: _cursorOf(fresh),
        hasMore: false,
      ),
    );
    await tester.pump();
    expect(arrived, <String>['new']);
  });

  test(
    'authenticated app root owns the only arrival listener and router context',
    () {
      final source = File('lib/app.dart').readAsStringSync();
      final shellSource = File(
        'lib/features/shell/pages/main_shell_page.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('sessionProvider.select(_notificationSessionKey)'),
      );
      expect(source, contains('ref.listen<String>('));
      expect(
        source,
        contains('ref.read(appNotificationProvider.notifier).clear()'),
      );
      expect(source, contains('session.status == AuthStatus.authenticated'));
      expect(source, contains('session.user?.can(Perm.noticeRead)'));
      expect(source, contains('NoticeArrivalListener('));
      expect(
        source,
        contains('routeContext: () => appNavigatorKey.currentContext'),
      );
      expect(shellSource, isNot(contains('NoticeArrivalListener(')));
    },
  );

  test('shared preferences cursor rejects a malformed UUID', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = SharedPreferencesNoticeArrivalCursorStore(preferences);
    const identity = 'cursor-validation-user';
    final valid = NoticeArrivalCursor(
      publishedAt: DateTime.utc(2026, 8, 22),
      id: '00000000-0000-0000-0000-000000000001',
    );

    await store.write(identity, valid, <String>{valid.id});
    expect((await store.read(identity))?.id, valid.id);
    expect(await store.readDeliveredIds(identity), <String>{valid.id});

    final key = preferences.getKeys().single;
    await preferences.setString(
      key,
      '{"publishedAt":"2026-08-22T00:00:00Z","id":"not-a-uuid"}',
    );
    expect(await store.read(identity), isNull);
    expect(await store.readDeliveredIds(identity), isEmpty);
  });
}

class _MemoryCursorStore implements NoticeArrivalCursorStore {
  final Map<String, NoticeArrivalCursor> values =
      <String, NoticeArrivalCursor>{};
  final Map<String, Set<String>> deliveredValues = <String, Set<String>>{};
  int writeCalls = 0;

  @override
  Future<NoticeArrivalCursor?> read(String identityKey) async =>
      values[identityKey];

  @override
  Future<Set<String>> readDeliveredIds(String identityKey) async =>
      Set<String>.of(deliveredValues[identityKey] ?? const <String>{});

  @override
  Future<void> write(
    String identityKey,
    NoticeArrivalCursor cursor,
    Set<String> deliveredIds,
  ) async {
    writeCalls++;
    values[identityKey] = cursor;
    deliveredValues[identityKey] = Set<String>.of(deliveredIds);
  }
}

NoticeArrivalCursor _epochCursor() => NoticeArrivalCursor(
  publishedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  id: NoticeArrivalCursor.zeroId,
);

NoticeArrivalPage _pageFromFeed(
  List<Notice> feed,
  NoticeArrivalCursor after, {
  int pageSize = 100,
}) {
  final later = feed.where((notice) => _noticeAfter(notice, after)).toList()
    ..sort((left, right) {
      final byTime = left.publishedAt.compareTo(right.publishedAt);
      return byTime != 0 ? byTime : left.id.compareTo(right.id);
    });
  final items = later.take(pageSize).toList(growable: false);
  return NoticeArrivalPage(
    items: items,
    cursor: items.isEmpty ? after : _cursorOf(items.last),
    hasMore: later.length > items.length,
  );
}

bool _noticeAfter(Notice notice, NoticeArrivalCursor cursor) {
  final byTime = notice.publishedAt.compareTo(cursor.publishedAt);
  return byTime > 0 || (byTime == 0 && notice.id.compareTo(cursor.id) > 0);
}

NoticeArrivalCursor _cursorOf(Notice notice) =>
    NoticeArrivalCursor(publishedAt: notice.publishedAt, id: notice.id);

Map<String, dynamic> _noticeJson(Notice notice) => <String, dynamic>{
  'id': notice.id,
  'title': notice.title,
  'content': notice.content,
  'type': notice.type.name,
  'publisher': notice.publisher,
  'publishedAt': notice.publishedAt.toUtc().toIso8601String(),
  'isRead': notice.isRead,
  'topPriority': notice.topPriority,
  'priority': notice.priority.name,
  'attachments': <String>[],
  'actionRoute': notice.actionRoute,
  'sourceEvent': notice.sourceEvent,
};

Notice _notice(
  String id, {
  required int minute,
  String? title,
  NoticePriority priority = NoticePriority.normal,
}) {
  return Notice(
    id: id,
    title: title ?? '通知 $id',
    content: '通知正文 $id',
    type: NoticeType.task,
    publisher: '系统',
    publishedAt: DateTime.utc(2026, 8, 22, 1, minute),
    isRead: false,
    priority: priority,
  );
}
