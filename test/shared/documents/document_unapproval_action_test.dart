import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/documents/document_unapproval.dart';
import 'package:uten_imp/shared/documents/document_unapproval_action.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/native_detail_reader_overrides.dart';

Map<String, dynamic> _ready([String hash = 'a']) => {
  'supported': true,
  'permitted': true,
  'eligible': true,
  'nextAction': 'UNAPPROVE_TO_DRAFT',
  'factsSnapshot': hash * 64,
  'reasons': <Object>[],
};

Map<String, dynamic> _blocked(String message) => {
  'supported': true,
  'permitted': true,
  'eligible': false,
  'nextAction': 'BLOCKED',
  'factsSnapshot': 'b' * 64,
  'reasons': [
    {'code': 'DOWNSTREAM_ACTIVE', 'message': message},
  ],
};

void main() {
  testWidgets(
    'pushed unapproval links retain the owning detail path and query',
    (tester) async {
      final router = await _pumpBannerRoutes(tester);
      await tester.tap(find.text('后续单据 FY-2'));
      await tester.pumpAndSettle();
      final successor = GoRouterState.of(
        tester.element(find.byKey(const ValueKey('page-successor'))),
      ).uri;
      expect(successor.path, '/finance/expenses/successor');
      expect(successor.queryParameters, {
        'history': '1',
        'returnTo': '/finance/expenses',
        'tab': 'attachments',
      });
      await tester.tap(find.text('反审前单据与附件'));
      await tester.pumpAndSettle();
      final original = GoRouterState.of(
        tester.element(find.byKey(const ValueKey('page-original'))),
      ).uri;
      expect(original.path, '/finance/expenses/original');
      expect(original.queryParameters, successor.queryParameters);
      expect(router.canPop(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('offstage unapproval banner keeps its own document identity', (
    tester,
  ) async {
    final rebuild = ValueNotifier(0);
    addTearDown(rebuild.dispose);
    final router = await _pumpBannerRoutes(tester, rebuild: rebuild);
    router.push('/finance/expenses/other?tab=other');
    await tester.pumpAndSettle();
    rebuild.value++;
    await tester.pump();
    final originalBanner = find.byKey(
      const ValueKey('banner-original'),
      skipOffstage: false,
    );
    final link = find.descendant(
      of: originalBanner,
      matching: find.widgetWithText(
        TextButton,
        '后续单据 FY-2',
        skipOffstage: false,
      ),
      skipOffstage: false,
    );
    expect(link, findsOneWidget);
    tester.widget<TextButton>(link).onPressed!();
    await tester.pumpAndSettle();
    final uri = GoRouterState.of(
      tester.element(find.byKey(const ValueKey('page-successor'))),
    ).uri;
    expect(uri.path, '/finance/expenses/successor');
    expect(uri.queryParameters['tab'], 'attachments');
    expect(uri.queryParameters['returnTo'], '/finance/expenses');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unapproval banner without its document route cannot expose unrelated links',
    (tester) async {
      await _pumpBannerRoutes(tester, bannerDocumentId: 'mismatched');
      expect(find.text('后续单据 FY-2'), findsNothing);
      expect(find.text('反审前单据与附件'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'blocked action explains the actual dependency and never invokes reversal',
    (tester) async {
      final api = _AvailabilityApi()..reply = _blocked('收货草稿尚未撤回，请先处理下游收货');
      var calls = 0;
      await _pump(tester, api, () => calls++);
      expect(
        tester.widget<UtenButton>(find.byType(UtenButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('反审'));
      await tester.pumpAndSettle();
      expect(find.text('暂不能反审'), findsOneWidget);
      expect(find.text('收货草稿尚未撤回，请先处理下游收货'), findsOneWidget);
      expect(calls, 0);
      expect(api.posts, 0);
    },
  );

  testWidgets(
    'new downstream work between rendering and clicking blocks the callback',
    (tester) async {
      final api = _AvailabilityApi();
      var calls = 0;
      await _pump(tester, api, () => calls++);
      expect(
        tester.widget<UtenButton>(find.byType(UtenButton)).onPressed,
        isNotNull,
      );
      api.reply = _blocked('原入库已有实际出库，请先处理后续出库');
      await tester.tap(find.text('反审'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(api.posts, 0);
      expect(
        tester.widget<UtenButton>(find.byType(UtenButton)).onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'identity change invalidates a pending allowed response and its private reason',
    (tester) async {
      final api = _AvailabilityApi()..holdNext = true;
      var calls = 0;
      final container = await _pump(tester, api, () => calls++, settle: false);
      await tester.pump();
      await tester.pump();
      final held = api.held!;
      api.reply = _blocked('当前身份没有反审权限');
      (container.read(sessionProvider.notifier) as _Reader).switchReader();
      await tester.pumpAndSettle();
      held.complete(_ready());
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenButton>(find.byType(UtenButton)).onPressed,
        isNull,
      );
      expect(find.text('私人下游单据'), findsNothing);
      expect(calls, 0);
      expect(api.posts, 0);
    },
  );

  testWidgets(
    'a failed capability read cannot enable the action and can be retried',
    (tester) async {
      final api = _AvailabilityApi()
        ..failure = ApiException('CONFLICT', '反审条件暂未完成核对');
      var calls = 0;
      await _pump(tester, api, () => calls++);
      expect(
        tester.widget<UtenButton>(find.byType(UtenButton)).onPressed,
        isNull,
      );
      api.failure = null;
      await tester.tap(find.text('重新核对反审'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenButton>(find.byType(UtenButton)).onPressed,
        isNotNull,
      );
      expect(calls, 0);
    },
  );

  testWidgets('cancelled read cannot publish or finish a later retry', (
    tester,
  ) async {
    final api = _AvailabilityApi();
    var calls = 0;
    await _pump(tester, api, () => calls++);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    api.holdNext = true;
    await tester.tap(find.text('反审'));
    await _paintReadWait(tester);
    final oldRead = api.held!;
    final afterStart = api.gets;
    expect(find.text('正在核对反审条件'), findsOneWidget);
    // A second button invocation cannot dispatch another capability read.
    final action = tester.widget<UtenButton>(find.byType(UtenButton).first);
    expect(action.onPressed, isNull);
    expect(api.gets, afterStart);
    await tester.tap(find.text('取消'));
    await _paintReadWait(tester);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(calls, 0);
    api.holdNext = true;
    await tester.tap(find.text('重新核对反审'));
    await _paintReadWait(tester);
    final newRead = api.held!;
    expect(newRead, isNot(same(oldRead)));
    oldRead.complete(_ready());
    await _paintReadWait(tester);
    expect(find.text('正在核对反审条件'), findsOneWidget);
    expect(calls, 0);
    newRead.complete(_ready('c'));
    await _paintReadWait(tester);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(calls, 0);
    expect(api.posts, 0);
    await tester.tap(find.text('反审'));
    await _paintReadWait(tester);
    expect(calls, 1);
  });

  testWidgets('completed read removes its mask before the confirmation opens', (
    tester,
  ) async {
    final api = _AvailabilityApi();
    var callbackMask = true;
    await _pump(tester, api, () {
      callbackMask = find.byType(UtenBusyOverlay).evaluate().isNotEmpty;
      return showDialog<void>(
        context: tester.element(find.byType(DocumentUnapprovalAction)),
        builder: (_) => const AlertDialog(title: Text('原业务确认')),
      );
    });
    api.holdNext = true;
    await tester.tap(find.text('反审'));
    await _paintReadWait(tester);
    expect(find.text('正在核对反审条件'), findsOneWidget);
    api.held!.complete(_ready());
    await _paintReadWait(tester);
    expect(callbackMask, isFalse);
    expect(find.text('原业务确认'), findsOneWidget);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(api.posts, 0);
  });

  testWidgets('blocked explanation retry waits and cancellation never writes', (
    tester,
  ) async {
    final api = _AvailabilityApi()..reply = _blocked('需先处理下游');
    var calls = 0;
    await _pump(tester, api, () => calls++);
    await tester.tap(find.text('反审'));
    await _paintReadWait(tester);
    expect(find.text('暂不能反审'), findsOneWidget);
    api.holdNext = true;
    await tester.tap(find.text('重新核对'));
    await _paintReadWait(tester);
    expect(find.text('暂不能反审'), findsNothing);
    expect(find.text('正在核对反审条件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _paintReadWait(tester);
    api.held!.complete(_ready());
    await _paintReadWait(tester);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(calls, 0);
    expect(api.posts, 0);
  });

  testWidgets(
    'changing reader disposes the user read mask and ignores late data',
    (tester) async {
      final api = _AvailabilityApi();
      var calls = 0;
      final container = await _pump(tester, api, () => calls++);
      api.holdNext = true;
      await tester.tap(find.text('反审'));
      await _paintReadWait(tester);
      final held = api.held!;
      (container.read(sessionProvider.notifier) as _Reader).switchReader();
      await _paintReadWait(tester);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      held.complete(_blocked('旧身份私有依赖'));
      await _paintReadWait(tester);
      expect(find.text('旧身份私有依赖'), findsNothing);
      expect(calls, 0);
      expect(api.posts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing the control cancels only its read presentation', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final api = _AvailabilityApi();
    var calls = 0;
    await _pump(tester, api, () => calls++, visible: visible);
    api.holdNext = true;
    await tester.tap(find.text('反审'));
    await _paintReadWait(tester);
    final held = api.held!;
    visible.value = false;
    await _paintReadWait(tester);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    held.complete(_ready());
    await _paintReadWait(tester);
    expect(calls, 0);
    expect(api.posts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'revision change invalidates old perform without clearing new one',
    (tester) async {
      final revision = ValueNotifier(1);
      addTearDown(revision.dispose);
      final api = _AvailabilityApi();
      var calls = 0;
      await _pump(tester, api, () => calls++, revision: revision);
      api.holdNext = true;
      await tester.tap(find.text('反审'));
      await _paintReadWait(tester);
      final oldRead = api.held!;
      revision.value++;
      await _paintReadWait(tester);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      api.holdNext = true;
      await tester.tap(find.text('反审'));
      await _paintReadWait(tester);
      final newRead = api.held!;
      oldRead.complete(_ready());
      await _paintReadWait(tester);
      expect(find.text('正在核对反审条件'), findsOneWidget);
      expect(calls, 0);
      newRead.complete(_ready('d'));
      await _paintReadWait(tester);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(calls, 1);
      expect(api.posts, 0);
    },
  );

  test(
    'confirmation binds the old snapshot and refuses a changed eligible generation',
    () async {
      final api = _AvailabilityApi()..reply = _ready('b');
      await expectLater(
        withDocumentUnapprovalSnapshot(
          'purchaseOrder',
          'original',
          'a' * 64,
          () async {
            await unapproveDocument(api, 'purchaseOrder', 'original');
          },
        ),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CONFLICT')),
      );
      expect(api.posts, 0);
    },
  );

  test(
    'blocked or unverified conditions never submit business effects',
    () async {
      final api = _AvailabilityApi();
      for (final reply in [
        _blocked('原应付已核销，请先反向核销'),
        {..._ready(), 'factsSnapshot': null},
        {..._ready(), 'permitted': false},
      ]) {
        api.reply = reply;
        await expectLater(
          unapproveDocument(api, 'financePayment', 'original'),
          throwsA(isA<ApiException>()),
        );
      }
      expect(api.posts, 0);
    },
  );

  test(
    'lost-response retry may retrieve the existing successor even though original is no longer eligible',
    () async {
      final api = _AvailabilityApi()
        ..reply = {..._blocked('原单据已反审'), 'nextAction': 'OPEN_SUCCESSOR'};
      final result = await unapproveDocument(api, 'purchaseOrder', 'original');
      expect(result['id'], 'successor');
      expect(api.posts, 1);
    },
  );
}

Future<void> _paintReadWait(WidgetTester tester) async {
  // Held reads keep the real busy animation running; settling is impossible.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<GoRouter> _pumpBannerRoutes(
  WidgetTester tester, {
  ValueNotifier<int>? rebuild,
  String? bannerDocumentId,
}) async {
  final revision = rebuild ?? ValueNotifier(0);
  if (rebuild == null) addTearDown(revision.dispose);
  Widget detail(BuildContext context, GoRouterState state) {
    final id = state.pathParameters['id']!;
    final edit = state.uri.path.endsWith('/edit');
    return Scaffold(
      key: ValueKey('page-$id${edit ? '-edit' : ''}'),
      body: ValueListenableBuilder<int>(
        valueListenable: revision,
        builder: (_, _, _) => DocumentUnapprovalBanner(
          key: ValueKey('banner-$id'),
          family: 'financeExpense',
          documentId: bannerDocumentId ?? id,
        ),
      ),
    );
  }

  final router = GoRouter(
    initialLocation: '/finance',
    routes: [
      GoRoute(
        path: '/finance',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => context.push('/finance/expenses'),
            child: const Text('费用列表'),
          ),
        ),
      ),
      GoRoute(
        path: '/finance/expenses',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => context.push(
              '/finance/expenses/original/edit?history=1'
              '&returnTo=%2Ffinance%2Fexpenses&tab=attachments',
            ),
            child: const Text('原单据详情'),
          ),
        ),
      ),
      GoRoute(path: '/finance/expenses/:id/edit', builder: detail),
      GoRoute(path: '/finance/expenses/:id', builder: detail),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        apiClientProvider.overrideWithValue(_BannerApi()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('费用列表'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('原单据详情'));
  await tester.pumpAndSettle();
  return router;
}

class _BannerApi extends ApiClient {
  _BannerApi() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'links': [
      {'originalId': 'original', 'draftId': 'successor', 'draftBillNo': 'FY-2'},
    ],
  };
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _AvailabilityApi api,
  FutureOr<void> Function() command, {
  bool settle = true,
  ValueNotifier<int>? revision,
  ValueNotifier<bool>? visible,
}) async {
  final currentRevision = revision ?? ValueNotifier(1);
  final currentVisibility = visible ?? ValueNotifier(true);
  if (revision == null) addTearDown(currentRevision.dispose);
  if (visible == null) addTearDown(currentVisibility.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(includeSession: false),
        sessionProvider.overrideWith(_Reader.new),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: Listenable.merge([currentRevision, currentVisibility]),
            builder: (_, _) => currentVisibility.value
                ? DocumentUnapprovalAction(
                    family: 'purchaseOrder',
                    documentId: 'original',
                    revision: currentRevision.value,
                    onPressed: command,
                  )
                : const SizedBox(),
          ),
        ),
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(DocumentUnapprovalAction)),
  );
  if (settle) await tester.pumpAndSettle();
  return container;
}

class _Reader extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'reader-a',
      code: 'A',
      name: '审核人A',
      employeeId: 'employee-a',
    ),
  );
  void switchReader() => state = const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'reader-b',
      code: 'B',
      name: '审核人B',
      employeeId: 'employee-b',
    ),
    impersonationReadOnly: true,
  );
}

class _AvailabilityApi extends ApiClient {
  _AvailabilityApi() : super(Dio());
  Map<String, dynamic> reply = _ready();
  ApiException? failure;
  int posts = 0;
  int gets = 0;
  bool holdNext = false;
  Completer<Map<String, dynamic>>? held;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    gets++;
    if (holdNext) {
      holdNext = false;
      held = Completer();
      return held!.future;
    }
    if (failure != null) throw failure!;
    return reply;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts++;
    return {'id': 'successor', 'unapprovalOriginalId': 'original', 'status': 0};
  }
}
