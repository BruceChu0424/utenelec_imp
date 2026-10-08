import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_arrival.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'server alerts serialize and acknowledge only after explicit action',
    (tester) async {
      final fixture = await _mount(tester);
      var delivered = 0;
      for (final notice in fixture.notices) {
        dispatchNoticeArrival(
          fixture.context,
          notice,
          onOpenDetail: () {},
          onDelivered: () => delivered++,
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('异常一'), findsOneWidget);
      expect(find.text('异常二'), findsNothing);
      expect(fixture.reads, isEmpty);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('异常一'), findsOneWidget);
      await tester.tap(find.text('已知悉'));
      await tester.pumpAndSettle();
      expect(delivered, 1);
      expect(fixture.reads, [fixture.notices.first.id]);
      expect(find.text('异常二'), findsOneWidget);
      await tester.tap(find.text('已知悉'));
      await tester.pumpAndSettle();
      expect(delivered, 2);
      await tester.pumpWidget(const SizedBox());
      fixture.container.dispose();
    },
  );

  testWidgets(
    'identity invalidation closes current alert and discards queued alerts',
    (tester) async {
      final fixture = await _mount(tester);
      final interrupt = ChangeNotifier();
      var current = true;
      var delivered = 0;
      for (final notice in fixture.notices) {
        dispatchNoticeArrival(
          fixture.context,
          notice,
          onOpenDetail: () {},
          onDelivered: () => delivered++,
          isCurrent: () => current,
          interruptSignal: interrupt,
        );
      }
      await tester.pumpAndSettle();
      current = false;
      interrupt.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('异常一'), findsNothing);
      expect(find.text('异常二'), findsNothing);
      expect(delivered, 0);
      expect(fixture.reads, isEmpty);
      await tester.pumpWidget(const SizedBox());
      interrupt.dispose();
      fixture.container.dispose();
    },
  );

  testWidgets('failed authorization refresh never shows stale alert content', (
    tester,
  ) async {
    final fixture = await _mount(tester, deny: true);
    var retries = 0;
    dispatchNoticeArrival(
      fixture.context,
      fixture.notices.first,
      onOpenDetail: () {},
      onRetry: () => retries++,
    );
    await tester.pumpAndSettle();
    expect(find.text('异常一'), findsNothing);
    expect(retries, 1);
    expect(fixture.reads, isEmpty);
    await tester.pumpWidget(const SizedBox());
    fixture.container.dispose();
  });

  for (final structured in [true, false]) {
    testWidgets('only authoritative deletion terminates arrival: $structured', (
      tester,
    ) async {
      final fixture = await _mount(
        tester,
        missing: true,
        structured: structured,
      );
      var delivered = 0;
      var retries = 0;
      dispatchNoticeArrival(
        fixture.context,
        fixture.notices.first,
        onOpenDetail: () {},
        onDelivered: () => delivered++,
        onRetry: () => retries++,
      );
      await tester.pumpAndSettle();
      expect(find.text('异常一'), findsNothing);
      expect(delivered, structured ? 1 : 0);
      expect(retries, structured ? 0 : 1);
      expect(fixture.reads, isEmpty);
      await tester.pumpWidget(const SizedBox());
      fixture.container.dispose();
    });
  }

  testWidgets(
    'deletion between acknowledgment and reread does not retry forever',
    (tester) async {
      final fixture = await _mount(tester, disappearOnRead: true);
      var delivered = 0;
      var retries = 0;
      dispatchNoticeArrival(
        fixture.context,
        fixture.notices.first,
        onOpenDetail: () {},
        onDelivered: () => delivered++,
        onRetry: () => retries++,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('已知悉'));
      await tester.pumpAndSettle();
      expect(delivered, 1);
      expect(retries, 0);
      expect(find.text('异常一'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      fixture.container.dispose();
    },
  );
}

Future<
  ({
    BuildContext context,
    ProviderContainer container,
    List<Notice> notices,
    List<String> reads,
  })
>
_mount(
  WidgetTester tester, {
  bool deny = false,
  bool missing = false,
  bool structured = true,
  bool disappearOnRead = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final notices = [
    for (var i = 1; i <= 2; i++)
      Notice(
        id: '00000000-0000-0000-0000-00000000000$i',
        title: i == 1 ? '异常一' : '异常二',
        content: '请核对服务器状态',
        type: NoticeType.urgent,
        publisher: '系统监控',
        publishedAt: DateTime.utc(2026, 10, 7),
        isRead: false,
        priority: NoticePriority.urgent,
        sourceEvent: 'SERVER_HOST_ALERT:event-$i',
        actionRoute: '/admin/server-status',
      ),
  ];
  final reads = <String>[];
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (deny) {
          handler.reject(
            DioException(
              requestOptions: request,
              response: Response(requestOptions: request, statusCode: 403),
            ),
          );
          return;
        }
        final notice = notices
            .where((n) => request.path.contains(n.id))
            .firstOrNull;
        if (notice != null &&
            (missing ||
                (disappearOnRead &&
                    request.method == 'GET' &&
                    reads.contains(notice.id)))) {
          handler.reject(
            DioException(
              requestOptions: request,
              response: Response(
                requestOptions: request,
                statusCode: 404,
                data: structured
                    ? {'code': 'NOT_FOUND', 'message': '通知不存在'}
                    : 'proxy missing',
              ),
            ),
          );
          return;
        }
        if (notice != null && request.method != 'GET') reads.add(notice.id);
        handler.resolve(
          Response(
            requestOptions: request,
            statusCode: 200,
            data: notice == null
                ? <String, dynamic>{'count': 0}
                : <String, dynamic>{
                    'id': notice.id,
                    'title': notice.title,
                    'content': notice.content,
                    'type': 'urgent',
                    'publisher': notice.publisher,
                    'publishedAt': notice.publishedAt.toIso8601String(),
                    'isRead': false,
                    'priority': 'urgent',
                    'sourceEvent': notice.sourceEvent,
                    'actionRoute': notice.actionRoute,
                    'attachments': <String>[],
                  },
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
  late BuildContext context;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('首页'));
          },
        ),
      ),
    ),
  );
  return (
    context: context,
    container: container,
    notices: notices,
    reads: reads,
  );
}
