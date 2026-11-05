import '../../support/finance_command_test_support.dart';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/pages/finance_application_settings_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';

const _roleId = '22222222-2222-4222-8222-222222222222';
const _employeeId = '33333333-3333-4333-8333-333333333333';
final _settingsGrants = StateProvider<Set<String>>(
  (_) => {Perm.expenseSettings},
);
final _settingsIdentity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'settings-owner'),
);

void main() {
  for (final action in ['settings', 'role', 'remove']) {
    testWidgets(
      '$action original command survives hard reopen and lost cancellation, then requires current CAS and explicit new save',
      (tester) async {
        final api = _Api()
          ..unwrittenFirst = true
          ..loseCancelFirst = true
          ..seedRole = action != 'settings';
        final storage = MemoryFormDraftStorage();
        var harness = await _mount(tester, api, storage);
        if (action == 'settings') {
          await _editSettings(tester);
        } else {
          await tester.tap(find.text('匿名审批人员'));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tap(find.text('匿名审批人员'));
          await tester.pumpAndSettle();
        }
        final reference = find.descendant(
          of: find.widgetWithText(
            UtenInput,
            action == 'settings' ? '启用/关闭依据' : '指派依据',
          ),
          matching: find.byType(TextField),
        );
        await tester.enterText(reference, '原设置与原人员输入 12.');
        if (action == 'remove') {
          await tester.tap(find.text('移除岗位人员'));
          await tester.pumpAndSettle();
          expect(api.writes, isEmpty);
          await tester.tap(find.text('确认移除'));
        } else {
          await tester.tap(find.text('保存'));
        }
        await tester.pumpAndSettle();
        final original = Map<String, dynamic>.from(api.writes.single);
        final draft = harness.container.read(formDraftsProvider).single;
        expect(draft.hasUnknownSubmission, isTrue);
        if (action == 'remove') {
          expect(draft.data['pendingAction'], 'REMOVE');
          expect(
            original.keys,
            unorderedEquals(['requestId', 'id', 'expectedVersion']),
          );
          expect(api.writeMethods.single.$1, 'DELETE');
        }
        await tester.pumpWidget(const SizedBox());
        harness.dispose();
        api.version = 99;
        if (action != 'settings') {
          api._roles = [
            {...api.roles.single, 'version': 99, 'employeeName': '当前另一人员'},
          ];
        }
        final uri = Uri.parse(draft.route);
        harness = await _mount(
          tester,
          api,
          storage,
          location: uri
              .replace(
                queryParameters: {...uri.queryParameters, 'draftId': draft.id},
              )
              .toString(),
        );
        expect(api.writes, hasLength(1));
        expect(
          harness.container.read(formDraftsProvider).single.data['sent'],
          original,
        );
        await tapFinanceOriginalAction(tester, '核实未写并保留输入');
        await tester.pumpAndSettle();
        expect(
          harness.container
              .read(formDraftsProvider)
              .single
              .hasUnknownSubmission,
          isTrue,
        );
        await tapFinanceOriginalAction(tester, '核对原设置结果');
        await tester.pumpAndSettle();
        expect(find.text('核对当前设置'), findsOneWidget);
        expect(api.writes, hasLength(1));
        expect(
          tester
              .widget<UtenInput>(
                find.widgetWithText(
                  UtenInput,
                  action == 'settings' ? '启用/关闭依据' : '指派依据',
                ),
              )
              .controller!
              .text,
          '原设置与原人员输入 12.',
        );
        await tester.tap(find.text('核对当前设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('采用当前版本，保留输入'));
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(1));
        expect(
          harness.container.read(formDraftsProvider).single.data['requestId'],
          original['requestId'],
        );
        if (action == 'remove') {
          await tester.tap(find.text('移除岗位人员'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认移除'));
        } else {
          await tester.tap(find.text('保存'));
        }
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(2));
        expect(api.writes.last['requestId'], isNot(original['requestId']));
        expect(api.writes.last['expectedVersion'], 99);
        for (final field in original.keys.where(
          (field) => !{'requestId', 'expectedVersion'}.contains(field),
        )) {
          expect(api.writes.last[field], original[field]);
        }
        expect(api.commits, 1);
        expect(harness.container.read(formDraftsProvider), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        harness.dispose();
      },
    );
  }

  testWidgets(
    'revoking expense settings masks old HR input and preserves its pending original request',
    (tester) async {
      final api = _Api()..unwrittenFirst = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _editSettings(tester);
      await tester.enterText(_reference(), '原账号配置依据');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原请求操作'));
      await tester.pumpAndSettle();
      final cancel = tester
          .widget<InkWell>(
            find
                .ancestor(
                  of: find.text('核实未写并保留输入'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!;
      harness.container.read(_settingsGrants.notifier).state = {};
      await tester.pumpAndSettle();
      cancel();
      await tester.pumpAndSettle();
      expect(find.byType(UtenInput), findsNothing);
      expect(find.text('访问范围已变化'), findsOneWidget);
      expect(api.cancellations, isEmpty);
      expect(api.writes, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );

  testWidgets(
    'an account change during cancel never adopts its late HR result into the new account',
    (tester) async {
      final api = _Api()
        ..unwrittenFirst = true
        ..cancelGate = Completer<void>();
      final storage = MemoryFormDraftStorage();
      final harness = await _mount(tester, api, storage);
      await _editSettings(tester);
      await tester.enterText(_reference(), '原账号配置依据');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pump();
      await tester.pump();
      harness.container.read(_settingsIdentity.notifier).state =
          const AuthenticatedScope(userId: 'another-settings-owner');
      await tester.pump();
      api.cancelGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenInput), findsNothing);
      expect(find.text('访问范围已变化'), findsOneWidget);
      expect(api.writes, hasLength(1));
      expect(api.commits, 0);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );

  testWidgets(
    'narrow large text settings keeps frozen input and all footer actions above the keyboard',
    (tester) async {
      const capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_DIALOGS');
      if (capture) await loadAuditScreenshotFonts(tester);
      final api = _Api()..loseFirst = true;
      final harness = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        width: 390,
        scale: 1.5,
        capture: capture,
      );
      await _editSettings(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_reference());
      expect(_reference().hitTestable(), findsOneWidget);
      await tester.enterText(_reference(), '原设置与原请求保留');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('原设置与原请求保留'), findsOneWidget);
      final footer = tester.getRect(find.byType(UtenDialogActions).first);
      expect(footer.bottom, lessThanOrEqualTo(600));
      expect(find.text('重试原设置').hitTestable(), findsOneWidget);
      if (capture) {
        await saveAuditScreenshot(
          tester,
          harness.boundary,
          'finance-settings-editor-390-keyboard',
        );
      }
      // The native scrollable dialog shares a viewport for title and fields.
      // Input positioning may scroll the title above that viewport; returning
      // to its origin must reveal the whole heading without clipping/overflow.
      final title = find.text('启用/关闭原申请流程');
      final titleViewport = find
          .ancestor(of: title, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(titleViewport).position;
      expect(position.pixels, greaterThan(0));
      position.jumpTo(0);
      await tester.pumpAndSettle();
      final titleRect = tester.getRect(title);
      final viewportRect = tester.getRect(titleViewport);
      expect(titleRect.top, greaterThanOrEqualTo(viewportRect.top));
      expect(titleRect.bottom, lessThanOrEqualTo(viewportRect.bottom));
      if (capture) {
        await saveAuditScreenshot(
          tester,
          harness.boundary,
          'finance-settings-editor-390-keyboard-top',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );

  testWidgets(
    'incomplete new role draft restores its original record identity without a write',
    (tester) async {
      final api = _Api(), storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await tester.tap(find.text('新增岗位人员'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.widgetWithText(UtenInput, '指派依据'),
          matching: find.byType(TextField),
        ),
        '岗位原始草稿 12.',
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final draft = harness.container.read(formDraftsProvider).single;
      final recordId = draft.data['id'];
      expect(Uri.parse(draft.route).queryParameters['roleId'], recordId);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
      harness = await _mount(
        tester,
        api,
        storage,
        location: Uri.parse(draft.route)
            .replace(
              queryParameters: {
                ...Uri.parse(draft.route).queryParameters,
                'draftId': draft.id,
              },
            )
            .toString(),
      );
      expect(find.text('岗位原始草稿 12.'), findsOneWidget);
      expect(
        harness.container.read(formDraftsProvider).single.data['id'],
        recordId,
      );
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );
  testWidgets(
    'lost settings reply survives hard reopen and replays original UUID/body/version after newer settings exist',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await _editSettings(tester);
      await tester.enterText(_reference(), '原始启用依据 12.');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(api.writes.single['expectedVersion'], 7);
      expect(api.writes.single['requestId'], isNotEmpty);
      expect(
        tester
            .widget<UtenInput>(find.widgetWithText(UtenInput, '启用/关闭依据'))
            .enabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
      final location = Uri.parse(draft.route)
          .replace(
            queryParameters: {
              ...Uri.parse(draft.route).queryParameters,
              'draftId': draft.id,
            },
          )
          .toString();
      harness = await _mount(tester, api, storage, location: location);
      expect(find.text('原始启用依据 12.'), findsOneWidget);
      expect(api.writes, hasLength(1));
      await tester.tap(find.text('重试原设置'));
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(2));
      expect(jsonEncode(api.writes.first), jsonEncode(api.writes.last));
      expect(api.commits, 1);
      expect(api.version, 9);
      expect(find.text('启用/关闭原申请流程'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );

  testWidgets(
    'missing receipt keeps the frozen request and matching receipt completes without another write',
    (tester) async {
      final api = _Api()
        ..loseFirst = true
        ..receiptFound = false;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _editSettings(tester);
      await tester.enterText(_reference(), '原设置核对依据');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tapFinanceOriginalAction(tester, '核对原设置结果');
      await tester.pumpAndSettle();
      expect(find.text('重试原设置'), findsOneWidget);
      expect(api.writes, hasLength(1));
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      api.receiptFound = true;
      await tapFinanceOriginalAction(tester, '核对原设置结果');
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(find.text('启用/关闭原申请流程'), findsNothing);
      expect(harness.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );

  testWidgets(
    'a dispatched validation rejection keeps original input frozen until matching cancellation proof',
    (tester) async {
      final api = _Api()..reject = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _editSettings(tester);
      await tester.enterText(_reference(), '不足');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final field = tester.widget<UtenInput>(
        find.widgetWithText(UtenInput, '启用/关闭依据'),
      );
      expect(field.enabled, isFalse);
      expect(field.controller!.text, '不足');
      expect(api.commits, 0);
      expect(find.text('重试原设置'), findsOneWidget);
      await tapFinanceOriginalAction(tester, '核对原设置结果');
      await tester.pumpAndSettle();
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenInput>(find.widgetWithText(UtenInput, '启用/关闭依据'))
            .enabled,
        isTrue,
      );
      expect(find.text('核对当前设置'), findsOneWidget);
      expect(api.writes, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );

  testWidgets(
    'pending settings save has one full overlay and rapid repeated callbacks issue one write',
    (tester) async {
      final api = _Api()..gate = Completer<void>();
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _editSettings(tester);
      await tester.enterText(_reference(), '连续操作保留原设置依据');
      final save = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '保存'))
          .onPressed!;
      for (var i = 0; i < 20; i++) {
        save();
      }
      for (var i = 0; i < 10 && api.writes.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump();
      expect(api.writes, hasLength(1));
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(api.commits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      harness.dispose();
    },
  );
}

Finder _reference() => find.descendant(
  of: find.widgetWithText(UtenInput, '启用/关闭依据'),
  matching: find.byType(TextField),
);
Future<void> _editSettings(WidgetTester tester) async {
  await tester.tap(find.text('启用/关闭'));
  await tester.pumpAndSettle();
}

class _Harness {
  _Harness(this.container, this.router, this.boundary);
  final ProviderContainer container;
  final GoRouter router;
  final GlobalKey boundary;
  void dispose() {
    router.dispose();
    container.dispose();
  }
}

Future<_Harness> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String location = '/finance/applications/settings',
  double width = 1280,
  double scale = 1,
  bool? capture,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://settings.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWith(
        (ref) => ref.watch(_settingsIdentity),
      ),
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_settingsGrants),
      ),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/finance/applications/settings',
        builder: (_, _) => const FinanceApplicationSettingsPage(),
      ),
    ],
  );
  final boundary = GlobalKey();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: capture == true
            ? auditScreenshotTheme(buildLightTheme())
            : buildLightTheme(),
        builder: (context, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, router, boundary);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool loseFirst = false, reject = false, receiptFound = true;
  bool seedRole = false, unwrittenFirst = false, loseCancelFirst = false;
  int version = 7, commits = 0;
  Completer<void>? gate, cancelGate;
  final writes = <Map<String, dynamic>>[];
  final writeMethods = <(String, String)>[];
  final cancellations = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  List<Map<String, dynamic>>? _roles;
  List<Map<String, dynamic>> get roles =>
      _roles ??
      (seedRole
          ? [
              {
                'id': _roleId,
                'version': 7,
                'roleKey': 'FINANCE_REVIEW_1',
                'departmentId': null,
                'departmentName': null,
                'employeeId': _employeeId,
                'employeeName': '匿名审批人员',
                'sourceReference': '原岗位配置依据',
              },
            ]
          : []);
  Map<String, dynamic> snapshot() => {
    'version': version,
    'enabled': false,
    'sourceReference': '',
    'roles': roles,
    'departments': <Object>[],
    'roleDefinitions': [
      {'key': 'FINANCE_REVIEW_1', 'label': '财务审核一'},
      {'key': 'DEPARTMENT_REVIEW', 'label': '部门审核'},
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/operations/')) {
      final receipt = receipts[path.split('/').last];
      if (!receiptFound || receipt == null) return {'found': false};
      if (receipt['outcome'] == 'CANCELLED_UNWRITTEN') {
        return Map<String, dynamic>.from(receipt);
      }
      // Existing successes predate the full proof envelope and keep old JSON.
      return {
        'found': true,
        'requestId': receipt['requestId'],
        'actorId': receipt['actorId'],
        'operation': receipt['operation'],
        'outcome': 'SUCCEEDED',
        'result': receipt['result'],
      };
    }
    return snapshot();
  }

  Future<Map<String, dynamic>> _execute(
    String path,
    String method,
    Map<String, dynamic> request,
  ) async {
    writes.add(Map<String, dynamic>.from(request));
    writeMethods.add((method, path));
    if (reject) {
      throw ApiException(
        'VALIDATION_FAILED',
        '请填写完整依据',
        hasResponseCode: true,
        httpStatus: 422,
      );
    }
    if (unwrittenFirst && writes.length == 1) throw NetworkTimeoutException();
    if (gate != null) await gate!.future;
    final id = request['requestId'] as String;
    var receipt = receipts[id];
    if (receipt == null) {
      commits++;
      final operation = method == 'DELETE'
          ? 'ROLE_REMOVE'
          : path.endsWith('/roles')
          ? 'ROLE_SAVE'
          : 'SETTINGS_SAVE';
      final expected = request['expectedVersion'] as int;
      final savedVersion = expected + 1;
      if (operation == 'ROLE_REMOVE') {
        _roles = roles.where((role) => role['id'] != request['id']).toList();
      } else if (operation == 'ROLE_SAVE') {
        _roles = [
          for (final role in roles)
            if (role['id'] != request['id']) role,
          {
            'id': request['id'],
            'version': savedVersion,
            'roleKey': request['roleKey'],
            'departmentId': request['departmentId'],
            'employeeId': request['employeeId'],
            'employeeName': '匿名审批人员',
            'sourceReference': request['sourceReference'],
          },
        ];
      }
      final result = Map<String, dynamic>.from(
        jsonDecode(jsonEncode({...snapshot(), 'version': savedVersion})) as Map,
      );
      receipt = {
        'found': true,
        'requestId': id,
        'actorId': 'settings-owner',
        'operation': operation,
        'outcome': 'SUCCEEDED',
        'method': method,
        'path': path,
        'requestBody': Map<String, dynamic>.from(request),
        'result': result,
      };
      receipts[id] = receipt;
      version =
          savedVersion +
          1; // A later independent configuration is not overwritten by a replay.
    }
    if (loseFirst && writes.length == 1) throw NetworkTimeoutException();
    return receipt['outcome'] == 'SUCCEEDED'
        ? Map<String, dynamic>.from(receipt['result'] as Map)
        : Map<String, dynamic>.from(receipt);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
    bool preserveUnauthorizedSession = false,
  }) async {
    final request = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(body)) as Map,
    );
    if (!path.endsWith('/cancel')) return _execute(path, 'POST', request);
    cancellations.add(request);
    final id = request['requestId'] as String;
    final receipt = receipts.putIfAbsent(
      id,
      () => {
        'found': true,
        'requestId': id,
        'actorId': request['actorId'],
        'operation': request['operation'],
        'outcome': 'CANCELLED_UNWRITTEN',
        'method': request['method'],
        'path': request['path'],
        'requestBody': request['requestBody'],
        'result': {'cancelled': true},
      },
    );
    if (cancelGate != null) await cancelGate!.future;
    if (loseCancelFirst && cancellations.length == 1) {
      throw NetworkTimeoutException();
    }
    return Map<String, dynamic>.from(receipt);
  }

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    await _execute(path, 'DELETE', {
      'requestId': query!['requestId'],
      'id': path.split('/').last,
      'expectedVersion': query['expectedVersion'],
    });
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/org/employee-references/by-ids'
      ? [
          {
            'id': _employeeId,
            'code': 'E1',
            'fullName': '匿名审批人员',
            'departmentId': null,
            'departmentName': null,
            'status': 'active',
            'accountStatus': 'active',
            'positionName': null,
          },
        ]
      : [];
}
