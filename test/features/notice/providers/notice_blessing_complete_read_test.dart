import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/feedback/uten_empty.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/widgets/notice_blessing.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../../support/pump_until.dart';

void main() {
  for (final count in [51, 1001]) {
    test(
      'notice full wall$count retains the literal tail in original50 batches',
      () async {
        final api = _WallApi(count);
        final repo = DioNoticeRepository(api);
        final rows = await repo.listBlessings('notice-1', page: 7, size: 3);
        expect(rows, hasLength(count));
        expect(rows.map((row) => row.id).toSet(), hasLength(count));
        expect(rows.last.id, 'g0-b-${count - 1}');
        expect(rows.last.senderName, '同事${count - 1}');
        expect(rows.last.content, '祝福第${count - 1}条原文');
        expect(api.reads.map((q) => q['page']), [
          for (var page = 1; page <= (count + 49) ~/ 50; page++) page,
        ]);
        expect(api.reads.every((q) => q['size'] == 50), isTrue);
        expect(api.reads.first.containsKey('readSnapshotRevision'), isFalse);
        expect(
          api.reads.skip(1).every((q) => q['readSnapshotRevision'] == 'a' * 64),
          isTrue,
        );
        expect(api.writes, 0);
      },
    );
  }
  test(
    'notice tail failure returns no prefix and explicit retry reads the whole wall',
    () async {
      final api = _WallApi(1001)..failTailOnce = true;
      final repo = DioNoticeRepository(api);
      await expectLater(
        repo.listBlessings('notice-1'),
        throwsA(isA<ApiException>()),
      );
      expect(api.reads.map((q) => q['page']), [1, 2]);
      final rows = await repo.listBlessings('notice-1');
      expect(rows, hasLength(1001));
      expect(rows.last.id, 'g0-b-1000');
      expect(api.reads.skip(2).map((q) => q['page']), [
        for (var page = 1; page <= 21; page++) page,
      ]);
      expect(api.writes, 0);
    },
  );
  test(
    'two notice wall consumers share one complete provider flight',
    () async {
      final api = _WallApi(51)..tail = Completer<Map<String, dynamic>>();
      final c = _container(api);
      addTearDown(c.dispose);
      final p = noticeBlessingsProvider('notice-1');
      final first = c.listen(p, (_, _) {});
      final second = c.listen(p, (_, _) {});
      addTearDown(first.close);
      addTearDown(second.close);
      final pending = c.read(p.future);
      await api.tailReached.future;
      expect(c.read(p).hasValue, isFalse);
      expect(api.reads.map((q) => q['page']), [1, 2]);
      api.tail!.complete(api.page(2, 50, 0));
      final rows = await pending;
      expect(rows, hasLength(51));
      expect(c.read(p).requireValue.last.id, 'g0-b-50');
      expect(api.reads, hasLength(2));
      expect(api.writes, 0);
    },
  );
  test(
    'notice owner successor cannot publish the old held wall tail',
    () async {
      final api = _WallApi(51)..tail = Completer<Map<String, dynamic>>();
      final c = _container(api);
      addTearDown(c.dispose);
      final p = noticeBlessingsProvider('notice-1');
      final sub = c.listen(p, (_, _) {});
      addTearDown(sub.close);
      final old = c.read(p.future);
      unawaited(old.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
      await api.tailReached.future;
      api.generation = 1;
      c.read(readScopeRevisionProvider.notifier).state++;
      await c.pump();
      final next = await c.read(p.future);
      expect(next, hasLength(51));
      expect(next.every((row) => row.id.startsWith('g1-')), isTrue);
      api.tail!.complete(api.page(2, 50, 0));
      await Future<void>.delayed(Duration.zero);
      await c.pump();
      expect(
        c.read(p).requireValue.every((row) => row.id.startsWith('g1-')),
        isTrue,
      );
      expect(
        api.reads.where((q) => q['generation'] == 0).map((q) => q['page']),
        [1, 2],
      );
      expect(
        api.reads.where((q) => q['generation'] == 1).map((q) => q['page']),
        [1, 2],
      );
      expect(api.writes, 0);
    },
  );
  testWidgets(
    'real notice all-wall renders1001 tail with local scroll and keeps card preview separate',
    (tester) async {
      final api = _WallApi(1001);
      final c = await _mount(tester, api);
      expect(api.reads, isEmpty);
      await _openWall(tester, 1001);
      await pumpUntil(
        tester,
        () => c.read(noticeBlessingsProvider('notice-1')).hasValue,
        reason: 'notice complete1001 wall did not publish',
      );
      final list = find.byType(ListView);
      expect(list, findsOneWidget);
      expect(
        tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
        1001,
      );
      final wallScrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      expect(wallScrollable, findsOneWidget);
      final position = tester.state<ScrollableState>(wallScrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      final before = api.reads.length;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('祝福第1000条原文'), findsOneWidget);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(api.reads, hasLength(before));
      expect(before, 21);
      expect(api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'real notice wall tail error offers retry without any new prefix',
    (tester) async {
      final api = _WallApi(51)..failTailOnce = true;
      final c = await _mount(tester, api);
      await _openWall(tester, 51);
      await pumpUntil(
        tester,
        () => c.read(noticeBlessingsProvider('notice-1')).hasError,
        reason: 'notice tail error did not settle',
      );
      expect(find.text('祝福第0条原文'), findsNothing);
      expect(find.byType(ListView), findsNothing);
      expect(api.reads.map((q) => q['page']), [1, 2]);
      final retry = find.text('重试');
      expect(retry, findsOneWidget);
      api.tail = Completer<Map<String, dynamic>>();
      final errorState = tester.widget<UtenEmpty>(find.byType(UtenEmpty));
      final retryAction = errorState.onAction!;
      for (var repeat = 0; repeat < 8; repeat++) {
        retryAction();
      }
      await pumpUntil(
        tester,
        () => api.tailReached.isCompleted,
        reason: 'notice retry did not reach its held tail',
      );
      await pumpUntil(
        tester,
        () => find.byType(UtenBusyOverlayCard).evaluate().isNotEmpty,
        reason:
            'notice retry wait overlay did not mount while its tail was held',
      );
      expect(api.reads.map((query) => query['page']), [1, 2, 1, 2]);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(c.read(noticeBlessingsProvider('notice-1')).isLoading, isTrue);
      // AsyncValue may retain the previous error during explicit refresh;
      // this newly rebuilt action must also share the pending provider read.
      final currentError = tester.widget<UtenEmpty>(find.byType(UtenEmpty));
      final currentRetry = currentError.onAction!;
      for (var repeat = 0; repeat < 8; repeat++) {
        currentRetry();
      }
      await tester.pump();
      expect(api.reads.map((query) => query['page']), [1, 2, 1, 2]);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      api.tail!.complete(api.page(2, 50, 0));
      await pumpUntil(
        tester,
        () => c.read(noticeBlessingsProvider('notice-1')).hasValue,
        reason: 'notice explicit retry did not finish whole51',
      );
      await pumpUntil(
        tester,
        () => find.byType(UtenBusyOverlayCard).evaluate().isEmpty,
        reason:
            'notice retry wait overlay did not retire after the complete result',
      );
      expect(
        c.read(noticeBlessingsProvider('notice-1')).requireValue,
        hasLength(51),
      );
      expect(api.reads.map((q) => q['page']), [1, 2, 1, 2]);
      expect(api.writes, 0);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

ProviderContainer _container(_WallApi api, {SharedPreferences? preferences}) =>
    ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://notice-wall.invalid/api'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'notice-reader'),
        ),
        currentPermissionsProvider.overrideWithValue(const {'notice:view'}),
        isSuperAdminProvider.overrideWithValue(false),
        if (preferences != null)
          sharedPreferencesProvider.overrideWithValue(preferences),
      ],
    );
Future<ProviderContainer> _mount(WidgetTester tester, _WallApi api) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = _container(api, preferences: prefs);
  addTearDown(c.dispose);
  final notice = Notice(
    id: 'notice-1',
    title: '庆典原件',
    content: '保留原文',
    type: NoticeType.birthday,
    publisher: '系统',
    publishedAt: DateTime.utc(2026, 11),
    isRead: true,
    interactionMode: NoticeInteractionMode.bless,
    blessingCount: api.count,
    recentBlessings: [
      NoticeBlessing(
        id: 'preview-only',
        senderName: '预览同事',
        content: '卡片预览保留',
        createdAt: DateTime.utc(2026, 11),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: NoticeInteractionSection(notice: notice),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

Future<void> _openWall(WidgetTester tester, int count) async {
  final context = tester.element(find.byType(NoticeInteractionSection));
  final label = AppLocalizations.of(context).noticeBlessingViewAll(count);
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

class _WallApi extends ApiClient {
  _WallApi(this.count)
    : super(Dio(BaseOptions(baseUrl: 'https://notice-wall.invalid/api')));
  final int count;
  int writes = 0, generation = 0;
  bool failTailOnce = false;
  final reads = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? tail;
  final tailReached = Completer<void>();
  Map<String, dynamic> page(int page, int size, int generation) => {
    'items': [
      for (var i = (page - 1) * size; i < page * size && i < count; i++)
        {
          'id': 'g$generation-b-$i',
          'senderName': '同事$i',
          'content': '祝福第$i条原文',
          'createdAt': '2026-11-01T00:00:00Z',
          'mine': false,
        },
    ],
    'page': page,
    'size': size,
    'total': count,
    'totalPages': (count + size - 1) ~/ size,
    'scope': 'all',
    'readScopeVersion': 'notice-scope-$generation',
    'readSnapshotRevision': (generation == 0 ? 'a' : 'b') * 64,
    'readDataVersion': (generation == 0 ? 'c' : 'd') * 64,
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expectSync(path, '/notices/notice-1/blessings/summaries');
    final current = generation;
    final q = Map<String, dynamic>.of(query ?? {});
    reads.add({...q, 'generation': current});
    final batch = q['page'] as int, size = q['size'] as int;
    expectSync(size, 50);
    expectSync(
      q['readSnapshotRevision'],
      batch == 1 ? isNull : (current == 0 ? 'a' : 'b') * 64,
    );
    if (batch == 2 && failTailOnce) {
      failTailOnce = false;
      throw ApiException('TEMPORARY', '祝福尾批暂时不可用', httpStatus: 503);
    }
    if (batch == 2 && current == 0 && tail != null && !tail!.isCompleted) {
      if (!tailReached.isCompleted) tailReached.complete();
      return tail!.future;
    }
    return page(batch, size, current);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes++;
    throw StateError('Read must never issue command');
  }

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    writes++;
    throw StateError('Read must never delete');
  }
}
