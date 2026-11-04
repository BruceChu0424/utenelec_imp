import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'memory_form_draft_storage.dart';

void main() {
  testWidgets(
    'a prior selection never downgrades a later committed precision failure to unwritten',
    (tester) async {
      final fixture = _Fixture(), storage = MemoryFormDraftStorage();
      fixture.adapter.writtenAfterChoice = true;
      var prompts = 0;
      fixture.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(4, 'DOWN');
      });
      var container = await _mount(tester, fixture.api, storage);
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(_Editor)) as FormDraftMixin<_Editor>;
      await state.saveFormDraftNow();
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(prompts, 1);
      expect(fixture.adapter.requests, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await _mount(tester, fixture.api, storage, resume: draft.id);
      fixture.adapter.writtenAfterChoice = false;
      fixture.adapter.succeed = true;
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(fixture.adapter.headers[1], fixture.adapter.headers[2]);
      expect(fixture.adapter.requests[1], fixture.adapter.requests[2]);
      expect(find.text('完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      fixture.dio.close(force: true);
    },
  );

  testWidgets(
    'precision after committed write keeps original unknown command and never prompts replay',
    (tester) async {
      final fixture = _Fixture(), storage = MemoryFormDraftStorage();
      fixture.adapter.writtenBeforePrecision = true;
      var prompts = 0;
      fixture.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(4, 'DOWN');
      });
      final container = await _mount(tester, fixture.api, storage);
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(_Editor)) as FormDraftMixin<_Editor>;
      await state.saveFormDraftNow();
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(fixture.adapter.requests, hasLength(1));
      expect(prompts, 0);
      expect(draft.data['sent'], isNotNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      fixture.dio.close(force: true);
    },
  );

  testWidgets(
    'choice checkpoint precedes replay and survives unknown hard close with exact original header',
    (tester) async {
      final fixture = _Fixture(), storage = MemoryFormDraftStorage();
      int prompts = 0;
      fixture.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(4, 'DOWN');
      });
      var container = await _mount(tester, fixture.api, storage);
      await tester.tap(find.text('发送'));
      await _until(tester, () => fixture.adapter.requests.length == 2);
      final draft = container.read(formDraftsProvider).single,
          meta = Map<String, dynamic>.from(
            draft.data[businessPrecisionDraftKey] as Map,
          );
      expect((meta['choices'] as Map)['ratio'], {
        'scale': 4,
        'rounding': 'DOWN',
      });
      expect(draft.hasUnknownSubmission, isTrue);
      fixture.adapter.pending!.completeError(
        DioException(
          requestOptions: fixture.adapter.options!,
          type: DioExceptionType.receiveTimeout,
        ),
      );
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(_Editor)) as FormDraftMixin<_Editor>;
      await state.saveFormDraftNow();
      final retained = container.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      fixture.adapter.succeed = true;
      container = await _mount(
        tester,
        fixture.api,
        storage,
        resume: retained.id,
      );
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(fixture.adapter.requests, hasLength(3));
      expect(fixture.adapter.headers[1], fixture.adapter.headers[2]);
      expect(fixture.adapter.requests[1], fixture.adapter.requests[2]);
      expect(find.text('完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      fixture.dio.close(force: true);
    },
  );
  testWidgets(
    'hard close while no-write choice is open resumes without a hidden default',
    (tester) async {
      final fixture = _Fixture(), storage = MemoryFormDraftStorage();
      final open = Completer<BusinessPrecisionChoice?>();
      fixture.coordinator.register((_) => open.future);
      var container = await _mount(tester, fixture.api, storage);
      await tester.tap(find.text('发送'));
      await _until(
        tester,
        () => container
            .read(formDraftsProvider)
            .any((draft) => draft.data[businessPrecisionDraftKey] != null),
      );
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isFalse);
      expect(
        (draft.data[businessPrecisionDraftKey] as Map)['choices'],
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      open.complete(null);
      await tester.pumpAndSettle();
      int prompts = 0;
      fixture.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(3, 'HALF_UP');
      });
      fixture.adapter.succeed = true;
      container = await _mount(tester, fixture.api, storage, resume: draft.id);
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(fixture.adapter.requests, hasLength(3));
      expect(find.text('完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      fixture.dio.close(force: true);
    },
  );
}

Future<void> _until(WidgetTester tester, bool Function() predicate) async {
  for (var i = 0; i < 60 && !predicate(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(predicate(), isTrue);
}

class _Fixture {
  _Fixture() {
    dio = Dio(BaseOptions(baseUrl: 'https://precision.test/api'));
    adapter = _Adapter();
    dio.httpClientAdapter = adapter;
    api = ApiClient(dio, precisionCoordinator: coordinator);
  }
  late final Dio dio;
  late final _Adapter adapter;
  late final ApiClient api;
  final coordinator = BusinessPrecisionCoordinator();
}

class _Adapter implements HttpClientAdapter {
  final requests = <Object?>[], headers = <String?>[];
  RequestOptions? options;
  Completer<ResponseBody>? pending;
  bool succeed = false;
  bool writtenBeforePrecision = false;
  bool writtenAfterChoice = false;
  ResponseBody _json(Map<String, dynamic> json, int status) =>
      ResponseBody.fromString(
        jsonEncode(json),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(jsonDecode(jsonEncode(request.data)));
    headers.add(request.headers[businessPrecisionHeader] as String?);
    options = request;
    if (headers.last == null) {
      return _json({
        'code': 'PRECISION_CHOICE_REQUIRED',
        'message': '本次选择',
        'details': {
          'calculationKey': 'ratio',
          'groupKey': 'ratio',
          'label': '本次费用分摊',
          'maxScale': 30,
          'reason': 'NON_TERMINATING',
          'notWritten': !writtenBeforePrecision,
        },
      }, 422);
    }
    if (writtenAfterChoice) {
      return _json({
        'code': 'PRECISION_CHOICE_REQUIRED',
        'message': '实际提交后计算待核',
        'details': {
          'calculationKey': 'ratio',
          'label': '本次费用分摊',
          'maxScale': 30,
          'reason': 'NON_TERMINATING',
          'notWritten': false,
        },
      }, 422);
    }
    if (succeed) {
      return _json({'saved': true}, 200);
    }
    pending = Completer<ResponseBody>();
    return pending!.future;
  }

  @override
  void close({bool force = false}) {}
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({this.resume});
  final String? resume;
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> with FormDraftMixin<_Editor> {
  final amount = TextEditingController(text: '12345678901234567890.1234');
  Map<String, dynamic>? sent;
  bool busy = false, done = false;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.financeApplicationExecute
      .spec(route: '/finance/applications/precision-original');
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => busy;
  @override
  bool get formDraftCanReplaySubmission => sent != null;
  @override
  String? get formDraftResumeId => widget.resume;
  @override
  Iterable<Listenable> get formDraftListenables => [amount];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'amount': amount.text,
    'sent': sent,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    amount.text = data['amount'].toString();
    sent = data['sent'] is Map
        ? Map<String, dynamic>.from(data['sent'] as Map)
        : null;
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> save() async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    try {
      sent ??= {'requestId': 'original-request', 'amount': amount.text};
      await runFormDraftSubmission(
        () => ref.read(apiClientProvider).post('/precision-write', body: sent),
      );
      await completeFormDraft();
      if (mounted) {
        setState(() => done = true);
      }
    } on ApiException {
      if (mounted && !formDraftHasUnknownSubmission) {
        sent = null;
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    Column(
      children: [
        if (done) const Text('完成'),
        UtenInput(
          controller: amount,
          label: '原输入',
          enabled: !busy && sent == null,
        ),
        UtenButton(
          onPressed: busy ? null : save,
          child: Text(sent == null ? '发送' : '重试原请求'),
        ),
      ],
    ),
  );
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  ApiClient api,
  MemoryFormDraftStorage storage, {
  String? resume,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://precision.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'precision-user'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.financeApplicationView,
        Perm.financeApplicationExecute,
      }),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: _Editor(resume: resume)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}
