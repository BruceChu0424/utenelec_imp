import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/api_provider_retry.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/notice/providers/notice_arrival.dart';
import 'package:uten_imp/features/admin/repositories/permission_template_repository.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/providers/notice_unread_index_provider.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import '../../../helpers/badge_summary_fixture.dart';

void main() {
  final providers = <String, ProviderListenable<Object?>>{
    'notice list': noticeListProvider,
    'notice detail': noticeDetailProvider('notice'),
    'today celebration': myCelebrationTodayProvider,
    'celebration settings': celebrationSettingsProvider,
    'permission templates': permissionTemplatesProvider,
    'permission bindings': permissionTemplateBindingsProvider,
  };
  for (final entry in providers.entries) {
    test(
      '${entry.key} releases a pending read after its final consumer leaves',
      () async {
        final f = _Fixture();
        addTearDown(f.dispose);
        final sub = f.container.listen(entry.value, (_, _) {});
        await f.adapter.ready(1);
        sub.close();
        await f.container.pump();
        await f.settle();
        expect(f.adapter.cancelled, [true]);
        expect(f.safety.pendingReadCount, 0);
      },
    );
  }

  test('notice refresh cannot replace a newer filter result', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    final sub = f.container.listen(noticeListProvider, (_, _) {});
    await f.adapter.ready(1);
    f.adapter.respond(0, {'items': <Object>[]});
    await f.container.read(noticeListProvider.future);
    final refresh = f.container.read(noticeListProvider.notifier).refresh();
    unawaited(refresh.catchError((Object _) {}));
    await f.adapter.ready(2);
    f.container.read(noticeFilterProvider.notifier).state = NoticeFilter.all;
    await f.container.pump();
    await f.adapter.ready(3);
    await f.settle();
    f.adapter.respond(2, {
      'items': [_notice('current')],
    });
    await f.container.read(noticeListProvider.future);
    f.adapter.respond(1, {
      'items': [_notice('retired')],
    });
    await f.settle();
    expect(
      f.container.read(noticeListProvider).requireValue.single.id,
      'current',
    );
    expect(f.adapter.cancelled[1], isTrue);
    sub.close();
  });

  test(
    'failed manual notice refresh completes normally and exposes its terminal error',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final sub = f.container.listen(noticeListProvider, (_, _) {});
      await f.adapter.ready(1);
      f.adapter.respond(0, {'items': <Object>[]});
      await f.container.read(noticeListProvider.future);
      final refresh = f.container.read(noticeListProvider.notifier).refresh();
      await f.adapter.ready(2);
      f.adapter.respond(1, {
        'code': 'TEMPORARY_UNAVAILABLE',
        'message': 'fixture failure',
      }, status: 503);
      await expectLater(refresh, completes);
      expect(f.container.read(noticeListProvider).hasError, isTrue);
      expect(f.container.read(noticeListProvider).isLoading, isFalse);
      await f.settle();
      expect(f.adapter.pending, hasLength(2));
      sub.close();
    },
  );

  test(
    'shared notice detail does not inherit a departing consumer fence',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      var caller = true;
      final provider = noticeDetailProvider('notice');
      final first = PagedReadIntent.scopedRead(
        () => caller,
        () => f.container.listen(provider, (_, _) {}),
      );
      final second = f.container.listen(provider, (_, _) {});
      await f.adapter.ready(1);
      caller = false;
      first.close();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, [false]);
      f.adapter.respond(0, _notice('notice'));
      expect((await f.container.read(provider.future))!.id, 'notice');
      second.close();
    },
  );

  test(
    'unread index cancels a retired identity and permits its successor to sync',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final sub = f.container.listen(noticeUnreadIndexProvider, (_, _) {});
      final prior = f.container.read(noticeUnreadIndexProvider.notifier).sync();
      await f.adapter.ready(1);
      f.container.read(f.identity.notifier).state = const AuthenticatedScope(
        userId: 'next',
      );
      await f.container.pump();
      final next = f.container.read(noticeUnreadIndexProvider.notifier).sync();
      await f.adapter.ready(2);
      await f.settle();
      expect(f.adapter.cancelled, [true, false]);
      f.adapter.respond(1, {
        'digest': 2,
        'unreadCount': 0,
        'items': <Object>[],
      });
      await next;
      await prior;
      expect(f.container.read(noticeUnreadIndexProvider)!.digest, 2);
      sub.close();
    },
  );

  test(
    'review eligibility batch cancels old identity without stranding its waiters',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final load = f.container.read(noticeReviewArrivalStatusProvider);
      final first = expectLater(load('first'), throwsA(isA<ApiException>()));
      final second = expectLater(load('second'), throwsA(isA<ApiException>()));
      await f.adapter.ready(1);
      f.container.read(f.identity.notifier).state = const AuthenticatedScope(
        userId: 'next',
      );
      await f.container.pump();
      await f.settle();
      await Future.wait([first, second]);
      expect(f.adapter.cancelled, [true]);
      final next = f.container.read(noticeReviewArrivalStatusProvider)(
        'current',
      );
      await f.adapter.ready(2);
      f.adapter.respond(1, {'items': <Object>[]});
      expect(await next, isNull);
    },
  );
}

Map<String, Object> _notice(String id) => {
  'id': id,
  'title': id,
  'content': '',
  'type': 'system',
  'publisherName': 'fixture',
  'publishedAt': '2026-11-10T00:00:00Z',
};

class _Fixture {
  final adapter = _Adapter();
  final safety = ApiMutationReloadSafety();
  final identity = StateProvider<AuthenticatedScope?>(
    (ref) => const AuthenticatedScope(userId: 'first'),
  );
  late final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
    ..httpClientAdapter = adapter;
  late final api = ApiClient(dio, reloadSafety: safety);
  late final container = ProviderContainer(
    retry: apiProviderRetry,
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(identity)),
      sensitiveReadBoundaryProvider.overrideWith(
        (ref) => SensitiveReadBoundary(
          identity: ref.watch(identity),
          api: api,
          permissions: {'authorization:manage'},
          superAdmin: true,
        ),
      ),
      fixedBadgeSummaryOverride(),
    ],
  );
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));
  Future<void> dispose() async {
    container.dispose();
    await settle();
    for (var i = 0; i < adapter.pending.length; i++) {
      if (!adapter.pending[i].isCompleted) adapter.respond(i, {});
    }
    dio.close(force: true);
  }
}

class _Adapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];
  final cancelled = <bool>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    final index = pending.length;
    final result = Completer<ResponseBody>();
    pending.add(result);
    cancelled.add(false);
    cancelFuture?.then((_) => cancelled[index] = true);
    return result.future;
  }

  Future<void> ready(int count) async {
    for (var i = 0; pending.length < count && i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(pending.length, count);
  }

  void respond(int index, Object body, {int status = 200}) =>
      pending[index].complete(
        ResponseBody.fromString(
          jsonEncode(body),
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
  @override
  void close({bool force = false}) {}
}
