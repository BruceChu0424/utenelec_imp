import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/paging/read_view_activity.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/scoped_category_read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_provider.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

// Retained reads use a monotonic activity ticket, independently from accepted
// authorization and command ownership. The baseline failures are kept in build logs.
class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
}

class _Source {
  int revision = 0;
  bool deny = false;
  final calls = <(int, int)>[];
  final holds = <(int, int), Completer<PagedResult<int>>>{};
  final predicates = <(int, int), bool Function()?>{};

  PagedResult<int> response(int revision, int page) => PagedResult(
    items: List.generate(100, (i) => revision * 10000 + (page - 1) * 100 + i),
    page: page,
    size: 100,
    total: revision == 0 ? 100 : 300,
    totalPages: revision == 0 ? 1 : 3,
    readScopeVersion: 'same-authorized-owner',
  );

  Future<PagedResult<int>> fetch(int revision, int page) async {
    calls.add((revision, page));
    final logical = PagedReadIntent.currentRead;
    final active = PagedReadIntent.currentTransportActivity;
    predicates[(revision, page)] = () =>
        (logical?.call() ?? true) && (active?.call() ?? true);
    if (deny) throw ApiException('FORBIDDEN', 'revoked', httpStatus: 403);
    return holds[(revision, page)]?.future ?? response(revision, page);
  }
}

class _View extends ConsumerStatefulWidget {
  const _View({super.key, required this.source, this.resume = false});
  final _Source source;
  final bool resume;
  @override
  ConsumerState<_View> createState() => _ViewState();
}

class _ViewState extends ConsumerState<_View>
    with ScopedPagedReadViewMixin<_View> {
  PagedResult<int>? accepted;
  final publications = <int>[];
  int refreshes = 0;
  int retirements = 0;
  int _ticket = 0;

  Future<PagedResult<int>> load({bool disableOldPrefetch = false}) async {
    final ticket = ++_ticket, revision = widget.source.revision;
    final result = await readScopedPage<int>(
      1,
      query: [widget.source, 'unchanged-query'],
      currentQuery: () => [widget.source, 'unchanged-query'],
      idOf: (row) => row,
      isCurrent: () => ticket == _ticket,
      fetchPage: (page) => widget.source.fetch(revision, page),
      canPrefetch: disableOldPrefetch ? () => false : null,
    );
    if (mounted && ticket == _ticket) {
      publications.add(revision);
      setState(() => accepted = result);
    }
    return result;
  }

  @override
  void scopedPagedReadOwnerChanged() {
    retirements++;
    _ticket++;
    if (mounted) setState(() => accepted = null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.resume) {
      ref.onPageResume('/list', () async {
        refreshes++;
        await load();
      });
    }
    return Scaffold(
      body: Text(
        'accepted=${accepted?.items.firstOrNull}:${accepted?.items.length}',
      ),
    );
  }
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
}

Future<(_ViewState, ProviderContainer)> _plain(
  WidgetTester tester,
  _Source source,
  ValueNotifier<bool> active,
) async {
  final key = GlobalKey<_ViewState>();
  final container = ProviderContainer(
    overrides: [exportContextEpochProvider.overrideWith(_Epoch.new)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          child: _View(key: key, source: source),
          builder: (_, visible, child) =>
              TickerMode(enabled: visible, child: child!),
        ),
      ),
    ),
  );
  return (key.currentState!, container);
}

final _source = Provider<_Source>((ref) => throw UnimplementedError());
final _leases = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<int>, String>(
      (ref, query) => ScopedPagedReadProviderLease<int>(ref, query: query),
      dependencies: [exportContextEpochProvider],
    );
final _pages = FutureProvider.autoDispose<PagedResult<int>>(
  (ref) {
    final source = ref.watch(_source), revision = source.revision;
    return ref
        .watch(_leases('Q'))
        .read(1, fetchPage: (page) => source.fetch(revision, page));
  },
  dependencies: [_source, _leases],
  retry: pagedReadProviderRetry,
);

class _ProviderView extends ConsumerWidget {
  const _ProviderView(this.label);
  final String label;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_leases('Q')).bindView(context, currentQuery: () => 'Q');
    final result = ref.watch(_pages);
    return Text('$label:${result.value?.items.length}');
  }
}

class _ResponseAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final replies = <Completer<ResponseBody>>[];
  final cancelled = <bool>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    final index = requests.length;
    requests.add(options);
    cancelled.add(false);
    final reply = Completer<ResponseBody>();
    replies.add(reply);
    cancelFuture?.then((_) {
      cancelled[index] = true;
      if (!reply.isCompleted) {
        reply.completeError(
          DioException(requestOptions: options, type: DioExceptionType.cancel),
        );
      }
    });
    return reply.future;
  }

  void respond(int index, Map<String, dynamic> value, {int status = 200}) =>
      replies[index].complete(
        ResponseBody.fromString(
          jsonEncode(value),
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
  @override
  void close({bool force = false}) {}
}

class _NetworkSource extends _Source {
  _NetworkSource(this.api);
  final ApiClient api;
  @override
  Future<PagedResult<int>> fetch(int revision, int page) async {
    calls.add((revision, page));
    final json = await api.get(
      '/current-rows',
      query: {'page': page, 'size': 100},
    );
    return PagedResult.fromJson(json, (row) => row['value'] as int);
  }
}

Future<void> _bindActivity(
  WidgetTester tester,
  ReadViewActivity activity,
  ValueNotifier<bool> active,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, enabled, _) => TickerMode(
          enabled: enabled,
          child: Builder(
            builder: (context) {
              activity.bindView(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
}

class _MappingGate extends UiWorkBudget {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> checkpoint([int items = 1]) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }
}

void main() {
  testWidgets(
    'explicit return waits for foreground before creating a fresh read',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      final releaseBackground = activity.retainBackground();
      addTearDown(releaseBackground);
      final source = _Source();
      var completed = false;
      final pending = () async {
        if (!await activity.waitForForeground(() => true)) return;
        await activity.runRead(
          () => true,
          () => loadCompletePagedResult<int>(
            isCurrent: () => true,
            idOf: (row) => row,
            loadPage: (page, size) => source.fetch(1, page),
          ),
        );
        completed = true;
      }();
      await _drain(tester);
      expect(source.calls, isEmpty);
      expect(completed, isFalse);
      active.value = true;
      await tester.pump();
      await _drain(tester);
      await pending;
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      expect(completed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('foreground wait cancels on disposal without starting a read', (
    tester,
  ) async {
    final activity = ReadViewActivity();
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await _bindActivity(tester, activity, active);
    final pending = activity.waitForForeground(() => true);
    activity.dispose();
    expect(await pending, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('foreground wait rejects a retired logical owner before return', (
    tester,
  ) async {
    final activity = ReadViewActivity();
    addTearDown(activity.dispose);
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await _bindActivity(tester, activity, active);
    var current = true;
    final pending = activity.waitForForeground(() => current);
    current = false;
    active.value = true;
    await tester.pump();
    expect(await pending, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'foreground pulse cannot wake an explicit return while hidden again',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      late BuildContext boundContext;
      var active = false, finished = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              boundContext = context;
              activity.bindView(context, isCurrent: () => active);
              return const SizedBox();
            },
          ),
        ),
      );
      final pending = activity.waitForForeground(() => true).then((value) {
        finished = value;
        return value;
      });
      active = true;
      activity.bindView(boundContext, isCurrent: () => active);
      active = false;
      activity.bindView(boundContext, isCurrent: () => active);
      await _drain(tester);
      expect(finished, isFalse);
      active = true;
      activity.bindView(boundContext, isCurrent: () => active);
      await _drain(tester);
      expect(await pending, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('foreground wait treats a throwing owner as retired', (
    tester,
  ) async {
    final activity = ReadViewActivity();
    addTearDown(activity.dispose);
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await _bindActivity(tester, activity, active);
    var retired = false;
    final pending = activity.waitForForeground(() {
      if (retired) throw StateError('owner disposed');
      return true;
    });
    retired = true;
    active.value = true;
    await tester.pump();
    expect(await pending, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'retained mixin: held batch2 retires under an opaque GoRouter cover; return reads fresh',
    (tester) async {
      final source = _Source(), key = GlobalKey<_ViewState>();
      final container = ProviderContainer(
        overrides: [exportContextEpochProvider.overrideWith(_Epoch.new)],
      );
      final router = GoRouter(
        initialLocation: '/list',
        routes: [
          GoRoute(
            path: '/list',
            builder: (_, _) => _View(key: key, source: source, resume: true),
          ),
          GoRoute(
            path: '/cover',
            builder: (_, _) => const Scaffold(body: Text('opaque-cover')),
          ),
        ],
      );
      final detach = attachPageResume(
        router,
        container.read(pageResumeProvider.notifier),
      );
      addTearDown(() {
        detach();
        router.dispose();
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      bumpPageResumeState(container.read(pageResumeProvider.notifier), '/list');
      final view = key.currentState!;
      final initial = view.load();
      await _drain(tester);
      await initial;
      final accepted = view.accepted!,
          binding = readWindowBindingOf(accepted.items)!;
      source.revision = 1;
      final gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      final old = view.load().then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      await _drain(tester);
      expect(source.calls, [(0, 1), (1, 1), (1, 2)]);
      unawaited(router.push<void>('/cover'));
      await tester.pumpAndSettle();
      expect(view.mounted, isTrue);
      expect(TickerMode.valuesOf(view.context).enabled, isFalse);
      final aliveCovered = source.predicates[(1, 2)]!();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      final outcome = await old;
      expect(
        source.calls.where((call) => call.$1 == 1).toList(),
        [(1, 1), (1, 2)],
        reason: 'Covered retained pages must not fetch batch3.',
      );
      expect(
        aliveCovered,
        isFalse,
        reason:
            'The production transport retirement predicate must become false.',
      );
      expect(outcome, isNot(isA<PagedResult<int>>()));
      expect(identical(view.accepted, accepted), isTrue);
      expect(binding.isCurrent, isTrue);
      source.revision = 2;
      router.pop();
      await tester.pumpAndSettle();
      await _drain(tester);
      expect(view.refreshes, 1);
      expect(view.publications, [0, 2]);
      expect(view.accepted!.items.first, 20000);
      expect(source.calls.where((call) => call.$1 == 2).toList(), [
        (2, 1),
        (2, 2),
        (2, 3),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'retained mixin: TickerMode cover-return ABA cannot revive the held old read',
    (tester) async {
      final source = _Source(), active = ValueNotifier(true);
      addTearDown(active.dispose);
      final (view, _) = await _plain(tester, source, active);
      final seed = view.load();
      await _drain(tester);
      await seed;
      final accepted = view.accepted!,
          binding = readWindowBindingOf(accepted.items)!;
      source.revision = 1;
      final gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      final old = view.load().then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      await _drain(tester);
      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      final outcome = await old;
      expect(source.calls.where((call) => call.$1 == 1).toList(), [
        (1, 1),
        (1, 2),
      ]);
      expect(outcome, isNot(isA<PagedResult<int>>()));
      expect(view.publications, [0]);
      expect(identical(view.accepted, accepted), isTrue);
      expect(binding.isCurrent, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'retained provider: bound inactive retained consumer stops its complete tail',
    (tester) async {
      final source = _Source()..revision = 1, active = ValueNotifier(true);
      addTearDown(active.dispose);
      final gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _source.overrideWithValue(source),
            exportContextEpochProvider.overrideWith(_Epoch.new),
          ],
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: active,
              child: const _ProviderView('one'),
              builder: (_, value, child) =>
                  TickerMode(enabled: value, child: child!),
            ),
          ),
        ),
      );
      await _drain(tester);
      active.value = false;
      await tester.pump();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      expect(
        source.calls,
        [(1, 1), (1, 2)],
        reason: 'A covered bound provider must stop its complete tail.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'queued resume: a return queued during a failed refresh still gets its fresh read',
    (tester) async {
      final source = _Source(), key = GlobalKey<_ViewState>();
      final container = ProviderContainer(
        overrides: [exportContextEpochProvider.overrideWith(_Epoch.new)],
      );
      final router = GoRouter(
        initialLocation: '/list',
        routes: [
          GoRoute(
            path: '/list',
            builder: (_, _) => _View(key: key, source: source, resume: true),
          ),
          GoRoute(
            path: '/cover',
            builder: (_, _) => const Scaffold(body: Text('opaque-cover')),
          ),
        ],
      );
      final detach = attachPageResume(
        router,
        container.read(pageResumeProvider.notifier),
      );
      addTearDown(() {
        detach();
        router.dispose();
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      bumpPageResumeState(container.read(pageResumeProvider.notifier), '/list');
      final view = key.currentState!;
      final seed = view.load();
      await _drain(tester);
      await seed;
      unawaited(router.push<void>('/cover'));
      await tester.pumpAndSettle();
      source.revision = 1;
      final gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      router.pop();
      await tester.pumpAndSettle();
      await _drain(tester);
      expect(view.refreshes, 1);
      expect(source.calls.contains((1, 2)), isTrue);
      unawaited(router.push<void>('/cover'));
      await tester.pumpAndSettle();
      source.revision = 2;
      router.pop();
      await tester.pumpAndSettle();
      await _drain(tester);
      expect(view.refreshes, 1, reason: 'The original refresh is still held.');
      gate.completeError(const UiWorkCancelled());
      await _drain(tester);
      expect(
        view.refreshes,
        2,
        reason:
            'A newer real return must survive failure/cancellation of the previous refresh.',
      );
      expect(view.publications, [0, 2]);
      expect(view.accepted!.items.first, 20000);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'GUARD shared provider: one covered binding cannot cancel another active consumer',
    (tester) async {
      final source = _Source()..revision = 1, active = ValueNotifier(true);
      addTearDown(active.dispose);
      final gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _source.overrideWithValue(source),
            exportContextEpochProvider.overrideWith(_Epoch.new),
          ],
          child: MaterialApp(
            home: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (_, value, _) => TickerMode(
                    enabled: value,
                    child: _ProviderView(
                      value ? 'first-active' : 'first-covered',
                    ),
                  ),
                ),
                const _ProviderView('second'),
              ],
            ),
          ),
        ),
      );
      await _drain(tester);
      active.value = false;
      await tester.pump();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      expect(find.text('second:300'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'GUARD PopupRoute: a modal/fullscreen-style dialog must not retire its live owner',
    (tester) async {
      final source = _Source()..revision = 1, active = ValueNotifier(true);
      addTearDown(active.dispose);
      final (view, _) = await _plain(tester, source, active);
      final gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      final pending = view.load();
      await _drain(tester);
      unawaited(
        showDialog<void>(
          context: view.context,
          builder: (_) => const AlertDialog(content: Text('owned-popup')),
        ),
      );
      await tester.pumpAndSettle();
      expect(ModalRoute.of(view.context)!.isCurrent, isFalse);
      expect(TickerMode.valuesOf(view.context).enabled, isTrue);
      gate.complete(source.response(1, 2));
      await _drain(tester);
      expect((await pending).items.length, 300);
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      expect(view.publications, [1]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'GUARD headless and canPrefetch:false reads still complete all legitimate batches',
    () async {
      final source = _Source()..revision = 1, reader = ScopedPagedRead<int>();
      addTearDown(reader.dispose);
      final result = await reader.read(
        1,
        scope: 'Q',
        fetchPage: (page) => source.fetch(1, page),
        isCurrent: () => true,
        canPrefetch: () => false,
      );
      expect(result.items.length, 300);
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      final container = ProviderContainer(
        overrides: [
          _source.overrideWithValue(source),
          exportContextEpochProvider.overrideWith(_Epoch.new),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(_pages, (_, _) {});
      addTearDown(subscription.close);
      expect((await container.read(_pages.future)).items.length, 300);
    },
  );

  testWidgets(
    'GUARD 403: confirmed loss of access still retires accepted private rows',
    (tester) async {
      final source = _Source(), active = ValueNotifier(true);
      addTearDown(active.dispose);
      final (view, _) = await _plain(tester, source, active);
      final seed = view.load();
      await _drain(tester);
      await seed;
      final binding = readWindowBindingOf(view.accepted!.items)!;
      source.deny = true;
      final error = expectLater(view.load(), throwsA(isA<ApiException>()));
      await _drain(tester);
      await error;
      expect(view.accepted, isNull);
      expect(binding.isCurrent, isFalse);
      expect(view.retirements, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'EDGE real Dio: received403 while covered stays403 and retires accepted rows',
    (tester) async {
      final adapter = _ResponseAdapter(),
          dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
      dio.httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final source = _NetworkSource(ApiClient(dio)),
          active = ValueNotifier(true);
      addTearDown(active.dispose);
      final (view, _) = await _plain(tester, source, active);
      final seed = view.load();
      await _drain(tester);
      expect(adapter.requests.length, 1);
      adapter.respond(0, {
        'items': List.generate(100, (i) => {'value': i}),
        'page': 1,
        'size': 100,
        'total': 100,
        'totalPages': 1,
      });
      await _drain(tester);
      await seed;
      final binding = readWindowBindingOf(view.accepted!.items)!;
      final pending = view.load();
      final denial = expectLater(
        pending,
        throwsA(
          isA<ApiException>()
              .having(
                (error) => error.httpStatus,
                'actual received status',
                403,
              )
              .having(
                (error) => error.code,
                'not rewritten as view cancellation',
                isNot('REQUEST_STALE'),
              ),
        ),
      );
      await _drain(tester);
      expect(adapter.requests.length, 2);
      active.value = false;
      await tester.pump();
      adapter.respond(1, {
        'code': 'FORBIDDEN',
        'message': 'received-denial',
      }, status: 403);
      await _drain(tester);
      await denial;
      expect(view.accepted, isNull);
      expect(binding.isCurrent, isFalse);
      expect(view.retirements, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'EDGE read before inactive bind allows only bounded bootstrap transport and no progress',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      final source = _Source()..revision = 1,
          gate = Completer<PagedResult<int>>();
      source.holds[(1, 1)] = gate;
      var progress = 0;
      final pending = activity
          .runRead(
            () => true,
            () => loadCompletePagedResult<int>(
              isCurrent: () => true,
              idOf: (row) => row,
              loadPage: (page, size) => source.fetch(1, page),
              onBatch: (_, _, _) => progress++,
            ),
          )
          .then<Object>((result) => result, onError: (Object error) => error);
      await _drain(tester);
      expect(source.calls, [(1, 1)]);
      await _bindActivity(tester, activity, active);
      expect(
        source.predicates[(1, 1)]!(),
        isTrue,
        reason:
            'Initial transport may finish one bootstrap; publishing still cannot.',
      );
      active.value = true;
      await tester.pump();
      gate.complete(source.response(1, 1));
      await _drain(tester);
      expect(await pending, isA<UiWorkCancelled>());
      expect(source.calls, [(1, 1)]);
      expect(progress, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'EDGE bound inactive admission makes no request and resumes once after return',
    (tester) async {
      var resumes = 0;
      final activity = ReadViewActivity(onResume: () => resumes++);
      addTearDown(activity.dispose);
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      final source = _Source()..revision = 1,
          gate = Completer<PagedResult<int>>();
      source.holds[(1, 1)] = gate;
      final pending = activity
          .runRead(
            () => true,
            () => loadCompletePagedResult<int>(
              isCurrent: () => true,
              idOf: (row) => row,
              loadPage: (page, size) => source.fetch(1, page),
            ),
          )
          .then<Object>((result) => result, onError: (Object error) => error);
      await _drain(tester);
      expect(source.calls, isEmpty);
      active.value = true;
      await tester.pump();
      gate.complete(source.response(1, 1));
      await _drain(tester);
      expect(await pending, isA<UiWorkCancelled>());
      expect(source.calls, isEmpty);
      expect(resumes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final cursor in [false, true]) {
    testWidgets(
      'EDGE mapping yield cover prevents hidden progress or next batch:cursor=$cursor',
      (tester) async {
        final activity = ReadViewActivity();
        addTearDown(activity.dispose);
        final active = ValueNotifier(true);
        addTearDown(active.dispose);
        await _bindActivity(tester, activity, active);
        final work = _MappingGate();
        var reads = 0, batches = 0, pages = 0;
        final pending = activity
            .runRead<Object>(() => true, () async {
              if (cursor) {
                return loadCompleteCursorSnapshot<
                  int,
                  ({List<int> rows, String? next}),
                  String
                >(
                  isCurrent: () => true,
                  idOf: (row) => row,
                  budget: work,
                  loadPage: (after, size) async {
                    reads++;
                    return (rows: List.generate(100, (i) => i), next: 'next');
                  },
                  rowsOf: (value) => value.rows,
                  nextCursorOf: (value) => value.next,
                  rebuildSnapshot: (_, rows) => (rows: rows, next: null),
                  onBatch: (_, _) => batches++,
                );
              }
              return loadCompletePagedResult<int>(
                isCurrent: () => true,
                idOf: (row) => row,
                budget: work,
                loadPage: (page, size) async {
                  reads++;
                  return PagedResult(
                    items: List.generate(100, (i) => i),
                    page: page,
                    size: 100,
                    total: 300,
                    totalPages: 3,
                  );
                },
                onBatch: (_, _, _) => batches++,
                onPage: (_) => pages++,
              );
            })
            .then<Object>((result) => result, onError: (Object error) => error);
        await _drain(tester);
        expect(work.entered.isCompleted, isTrue);
        active.value = false;
        await tester.pump();
        active.value = true;
        await tester.pump();
        work.release.complete();
        await _drain(tester);
        expect(await pending, isA<UiWorkCancelled>());
        expect(reads, 1);
        expect(batches, 0);
        expect(pages, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'EDGE background demand continues shared full read while UI hides',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      final source = _Source()..revision = 1,
          gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      final release = activity.retainBackground();
      final pending = activity.runRead(
        () => true,
        () => loadCompletePagedResult<int>(
          isCurrent: () => true,
          idOf: (row) => row,
          loadPage: (page, size) => source.fetch(1, page),
        ),
      );
      await _drain(tester);
      active.value = false;
      await tester.pump();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      expect((await pending).items.length, 300);
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      release();
      release();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'EDGE last background release retires tail when all UI is inactive',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      final source = _Source()..revision = 1,
          gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      final release = activity.retainBackground();
      final pending = activity
          .runRead(
            () => true,
            () => loadCompletePagedResult<int>(
              isCurrent: () => true,
              idOf: (row) => row,
              loadPage: (page, size) => source.fetch(1, page),
            ),
          )
          .then<Object>((result) => result, onError: (Object error) => error);
      await _drain(tester);
      active.value = false;
      await tester.pump();
      release();
      release();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      expect(await pending, isA<UiWorkCancelled>());
      expect(source.calls, [(1, 1), (1, 2)]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('EDGE obsolete A finally cannot erase current B resume demand', (
    tester,
  ) async {
    var resumes = 0, aCurrent = true;
    final activity = ReadViewActivity(onResume: () => resumes++);
    addTearDown(activity.dispose);
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await _bindActivity(tester, activity, active);
    final a = Completer<int>(), b = Completer<int>();
    final old = activity
        .runRead(() => aCurrent, () => a.future)
        .then<Object>((x) => x, onError: (Object e) => e);
    final current = activity
        .runRead(() => true, () => b.future)
        .then<Object>((x) => x, onError: (Object e) => e);
    active.value = false;
    await tester.pump();
    aCurrent = false;
    b.complete(2);
    await _drain(tester);
    a.complete(1);
    await _drain(tester);
    await old;
    await current;
    active.value = true;
    await tester.pump();
    await _drain(tester);
    expect(resumes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'EDGE inactive new admission keeps fresh demand after old intent cleared',
    (tester) async {
      var resumes = 0, oldCurrent = true;
      final activity = ReadViewActivity(onResume: () => resumes++);
      addTearDown(activity.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      await activity.runRead(() => oldCurrent, () async => 1);
      active.value = false;
      await tester.pump();
      oldCurrent = false;
      final outcome = await activity
          .runRead(() => true, () async => 2)
          .then<Object>((x) => x, onError: (Object e) => e);
      expect(outcome, isA<UiWorkCancelled>());
      active.value = true;
      await tester.pump();
      await _drain(tester);
      expect(resumes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'EDGE retired activity rejects a newly started HTTP read before dispatch',
    () async {
      final adapter = _ImmediateAdapter(),
          dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
      dio.httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      await expectLater(
        PagedReadIntent.scopedRead(
          () => true,
          () => ApiClient(dio).get('/not-needed'),
          activity: PagedReadActivityFence(isCurrent: () => false),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'retirement',
            'REQUEST_STALE',
          ),
        ),
      );
      expect(
        adapter.requests,
        0,
        reason:
            'Visibility already retired before HTTP admission; no timer-delayed extra dispatch.',
      );
    },
  );
  test(
    'EDGE nested bootstrap cannot bypass a retired outer activity fence',
    () async {
      var calls = 0;
      final result = PagedReadIntent.scopedRead(
        () => true,
        () => PagedReadIntent.scopedRead(
          () => true,
          () => loadCompletePagedResult<int>(
            isCurrent: () => true,
            loadPage: (page, size) async {
              calls++;
              return const PagedResult(
                items: [1],
                page: 1,
                size: 100,
                total: 1,
                totalPages: 1,
              );
            },
          ),
          activity: PagedReadActivityFence(
            isCurrent: () => false,
            allowInactiveBootstrap: true,
          ),
        ),
        activity: PagedReadActivityFence(isCurrent: () => false),
      );
      await expectLater(result, throwsA(isA<UiWorkCancelled>()));
      expect(calls, 0);
    },
  );
  testWidgets(
    'EDGE a query-changed binding cannot cancel the other current query consumer',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      final firstQuery = ValueNotifier('Q');
      addTearDown(firstQuery.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              ValueListenableBuilder<String>(
                valueListenable: firstQuery,
                builder: (_, query, _) => Builder(
                  builder: (context) {
                    activity.bindView(
                      context,
                      isCurrent: () => firstQuery.value == 'Q',
                    );
                    return Text(query);
                  },
                ),
              ),
              Builder(
                builder: (context) {
                  activity.bindView(context, isCurrent: () => true);
                  return const Text('second Q');
                },
              ),
            ],
          ),
        ),
      );
      final source = _Source()..revision = 1,
          gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      final pending = activity.runRead(
        () => true,
        () => loadCompletePagedResult<int>(
          isCurrent: () => true,
          idOf: (row) => row,
          loadPage: (page, size) => source.fetch(1, page),
        ),
      );
      await _drain(tester);
      firstQuery.value = 'B';
      await tester.pump();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      expect((await pending).items.length, 300);
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'EDGE late background demand cannot revive an old retired ticket',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      final source = _Source()..revision = 1,
          gate = Completer<PagedResult<int>>();
      source.holds[(1, 2)] = gate;
      final old = activity
          .runRead(
            () => true,
            () => loadCompletePagedResult<int>(
              isCurrent: () => true,
              idOf: (row) => row,
              loadPage: (page, size) => source.fetch(1, page),
            ),
          )
          .then<Object>((x) => x, onError: (Object e) => e);
      await _drain(tester);
      active.value = false;
      await tester.pump();
      final release = activity.retainBackground();
      gate.complete(source.response(1, 2));
      await _drain(tester);
      expect(await old, isA<UiWorkCancelled>());
      expect(source.calls, [(1, 1), (1, 2)]);
      final fresh = activity.runRead(
        () => true,
        () => loadCompletePagedResult<int>(
          isCurrent: () => true,
          idOf: (row) => row,
          loadPage: (page, size) => source.fetch(2, page),
        ),
      );
      await _drain(tester);
      expect((await fresh).items.length, 300);
      release();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('EDGE independent slots preserve each current resume demand', (
    tester,
  ) async {
    var refreshes = 0, obsolete = false;
    final activity = ReadViewActivity(onResume: () => refreshes++);
    addTearDown(activity.dispose);
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await _bindActivity(tester, activity, active);
    final runs = Completer<int>(), periods = Completer<int>();
    final a = activity
        .runRead(() => true, () => runs.future, slot: 'runs')
        .then<Object>((x) => x, onError: (Object e) => e);
    final b = activity
        .runRead(() => !obsolete, () => periods.future, slot: 'periods')
        .then<Object>((x) => x, onError: (Object e) => e);
    active.value = false;
    await tester.pump();
    obsolete = true;
    periods.complete(2);
    runs.complete(1);
    await _drain(tester);
    await a;
    await b;
    active.value = true;
    await tester.pump();
    await _drain(tester);
    expect(refreshes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'EDGE a new input waiting for debounce owns its refresh instead of old fallback',
    (tester) async {
      var refreshes = 0, query = 'A';
      final activity = ReadViewActivity(onResume: () => refreshes++);
      addTearDown(activity.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      await activity.runRead(() => query == 'A', () async => 1);
      active.value = false;
      await tester.pump();
      query = 'B';
      active.value = true;
      await tester.pump();
      await _drain(tester);
      expect(refreshes, 0);
      await activity.runRead(() => query == 'B', () async => 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'EDGE shared producer survives its first foreground consumer leaving',
    (tester) async {
      final activity = ReadViewActivity();
      addTearDown(activity.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      final shared = ScopedCategoryRead();
      addTearDown(shared.dispose);
      final gate = Completer<PagedResult<int>>();
      var owner = true, fetches = 0;
      bool Function()? captured;
      Future<PagedResult<int>> fetch() async {
        fetches++;
        captured = PagedReadIntent.currentRead;
        return gate.future;
      }

      final first = activity
          .runRead(() => owner, () async {
            return (await shared.read(query: 'Q', fetch: fetch)).total;
          })
          .then<Object>((x) => x, onError: (Object e) => e);
      await _drain(tester);
      final second = shared.read(query: 'Q', fetch: fetch);
      owner = false;
      active.value = false;
      await tester.pump();
      expect(
        captured!(),
        isTrue,
        reason:
            'The producer has its own owner, not the first consumer logical or view predicate.',
      );
      gate.complete(
        const PagedResult(
          items: [7],
          page: 1,
          size: 100,
          total: 1,
          totalPages: 1,
        ),
      );
      await _drain(tester);
      expect((await second).items, [7]);
      expect(fetches, 1);
      expect(await first, isA<UiWorkCancelled>());
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'EDGE UI return while background demand lives still schedules one fresh foreground read',
    (tester) async {
      var refreshes = 0;
      final activity = ReadViewActivity(onResume: () => refreshes++);
      addTearDown(activity.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _bindActivity(tester, activity, active);
      final release = activity.retainBackground(), gate = Completer<int>();
      final pending = activity.runRead(() => true, () => gate.future);
      active.value = false;
      await tester.pump();
      await _drain(tester);
      expect(
        refreshes,
        0,
        reason: 'Background demand is no permission to refresh hidden UI.',
      );
      active.value = true;
      await tester.pump();
      await _drain(tester);
      expect(
        refreshes,
        0,
        reason:
            'The existing complete-set flight still owns its stable snapshot.',
      );
      gate.complete(1);
      await _drain(tester);
      expect(await pending, 1);
      expect(
        refreshes,
        1,
        reason:
            'A real foreground return still revalidates the server after the older background snapshot settles.',
      );
      release();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _ImmediateAdapter implements HttpClientAdapter {
  var requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
