import '../../support/finance_command_test_support.dart';
import '../../support/document_scope_capability_overrides.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../support/finance_document_command_fixture.dart';
import '../../support/native_detail_reader_overrides.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _id = '00000000-0000-0000-0000-000000000401';
const _actor = '00000000-0000-0000-0000-000000000101';
final _permissions = StateProvider<Set<String>>((_) => {});

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: _actor,
      code: 'F',
      name: '测试财务',
      permissions: ref.watch(_permissions).toList(),
    ),
  );
}

class _Api extends ApiClient {
  _Api(this.type) : super(Dio());
  final FinanceDocType type;
  final commands = <Map<String, dynamic>>[],
      cancellations = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  bool reject = true, loseCancel = true;
  String amount = '100.000000000000000000000001', generation = 'a';
  Map<String, dynamic> get detail => {
    ...financeReviewedDetailFixture({
      'id': _id,
      'billNo': '原单据',
      'makerId': 'maker',
      'billDate': '2026-11-04',
      'status': 0,
      'accountId': 'account',
      'outAccountId': 'account',
      'currencyId': 'cny',
      'exchangeRateExact': '1',
      'paymentMethodId': 'method',
      'receiptMethodId': 'method',
      'amountLocalExact': amount,
      'items': [
        {
          'id': 'line',
          'expenseStyleId': 'style',
          'incomeStyleId': 'style',
          'departmentId': null,
          'inAccountId': 'account2',
          'occurDate': '2026-11-04',
          'amountOriginalExact': amount,
          'amountLocalExact': amount,
          'remark': '原行',
        },
      ],
    }, type),
    'approvalSnapshot': List.filled(64, generation).join(),
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('/review-operations/')
      ? receipts[path.split('/').last] ?? {'found': false}
      : detail;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('accounts')) {
      return [
        for (final id in ['account', 'account2'])
          {
            'id': id,
            'name': id,
            'currencyId': 'cny',
            'baseCurrency': true,
            'currencyCode': 'CNY',
            'currencyName': '人民币',
            'status': '使用',
          },
      ];
    }
    if (path.contains('currencies')) {
      return [
        {'id': 'cny', 'name': '人民币', 'baseCurrency': true, 'exchangeRate': '1'},
      ];
    }
    if (path.contains('reference-methods')) {
      return [
        {'id': 'method', 'name': '银行转账', 'legacyNameConfirmed': true},
      ];
    }
    if (path.contains('payment-styles')) {
      return [
        {
          'id': 'style',
          'name': '原项目',
          'code': 'E01',
          'category': query?['category'],
          'children': <Object>[],
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final command = Map<String, dynamic>.from(body as Map);
    commands.add(command);
    final old = receipts[command['requestId']];
    if (old != null) return old;
    if (reject) {
      throw ApiException(
        'CONFLICT',
        '原单据已变化',
        httpStatus: 409,
        hasResponseCode: true,
      );
    }
    return receipts[command['requestId']
        as String] = financeReviewReceiptFixture(
      path: path,
      command: command,
      result: detail,
      actorId: _actor,
    );
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (!path.endsWith('/cancel')) throw StateError('unexpected post');
    final value = Map<String, dynamic>.from(body as Map);
    cancellations.add(value);
    final command = Map<String, dynamic>.from(value['requestBody'] as Map),
        key = value['requestId'] as String;
    final result = receipts.putIfAbsent(
      key,
      () => {
        ...financeReviewReceiptFixture(
          path: value['path'] as String,
          command: command,
          result: {'cancelled': true},
          actorId: _actor,
        ),
        'outcome': 'CANCELLED_UNWRITTEN',
      },
    );
    if (loseCancel) {
      loseCancel = false;
      throw NetworkTimeoutException();
    }
    return result;
  }
}

Future<({ProviderContainer container, GoRouter router})> _open(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? location,
  bool write = true,
  bool productionGuard = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final cfg = FinanceDocConfig.by(api.type);
  final container = ProviderContainer(
    overrides: [
      financeWriteAllDocumentScope(),
      apiBaseUrlProvider.overrideWithValue('https://finance-edit.test/api'),
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: _actor),
      ),
      sessionProvider.overrideWith(_Session.new),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
      ...nativeDetailReaderOverrides(
        includeSession: false,
        includeServer: false,
      ),
    ],
  );
  container.read(_permissions.notifier).state = {
    cfg.listPerm,
    if (write) cfg.editPerm!,
  };
  final real = container.read(appRouterProvider);
  GoRoute route(String path) {
    GoRoute? find(List<RouteBase> routes) {
      for (final r in routes) {
        if (r is GoRoute && r.path == path) return r;
        final nested = find(r.routes);
        if (nested != null) return nested;
      }
      return null;
    }

    return find(real.configuration.routes)!;
  }

  final edit = route('/finance/:seg/:id/edit'),
      detail = route('/finance/:seg/:id'),
      denied = route('/access-denied');
  final router = GoRouter(
    initialLocation: location ?? '/finance/${api.type.pathSegment}/$_id/edit',
    redirect: productionGuard ? real.configuration.topRedirect : null,
    routes: [
      DraftAwareGoRoute(
        path: edit.path,
        builder: edit.builder,
        redirect: edit.redirect,
      ),
      DraftAwareGoRoute(
        path: detail.path,
        builder: detail.builder,
        redirect: detail.redirect,
      ),
      GoRoute(
        path: denied.path,
        builder: denied.builder,
        redirect: denied.redirect,
      ),
      GoRoute(
        path: '/dashboard',
        builder: (_, _) => const Scaffold(body: Text('工作台')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: buildLightTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, router: router);
}

Future<void> _close(
  WidgetTester tester,
  ({ProviderContainer container, GoRouter router}) env,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  env.router.dispose();
  env.container.dispose();
}

FinanceGridRow _row(WidgetTester tester) => tester
    .widget<UtenEditableGrid<FinanceGridRow>>(
      find.byType(UtenEditableGrid<FinanceGridRow>),
    )
    .controller
    .rows
    .single;
void main() {
  for (final type in [
    FinanceDocType.expense,
    FinanceDocType.otherIncome,
    FinanceDocType.bankTransfer,
  ]) {
    testWidgets(
      '$type original edit binds nullable generation and exact raw input, view-only hard recovery cannot replay and can resolve lost cancel',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _Api(type), storage = MemoryFormDraftStorage();
        var env = await _open(tester, api, storage);
        expect(
          find.byType(UtenEditableGrid<FinanceGridRow>),
          findsOneWidget,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((w) => w.data)
              .join(' | '),
        );
        const entered = '200.000000000000000000000001';
        _row(tester).amount.text = entered;
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(api.commands, hasLength(1));
        final original = api.commands.single;
        expect(original['expectedVersion'], isNull);
        expect(original['expectedSnapshot'], List.filled(64, 'a').join());
        expect(
          (((original['document'] as Map)['items'] as List).single
              as Map)['amountOriginal'],
          entered,
        );
        final draft = env.container.read(formDraftsProvider).single;
        expect(draft.hasUnknownSubmission, isTrue);
        api.amount = '300.0000';
        api.generation = 'b';
        await _close(tester, env);
        env = await _open(
          tester,
          api,
          storage,
          location: draft.resumeLocation,
          write: false,
          productionGuard: true,
        );
        expect(find.byType(FinanceDocEditPage), findsOneWidget);
        expect(_row(tester).amount.text, entered);
        await tapFinanceOriginalAction(tester, '核对原保存结果');
        await tester.pumpAndSettle();
        expect(api.commands, hasLength(1));
        await tapFinanceOriginalAction(tester, '核实未写并保留输入');
        await tester.pumpAndSettle();
        expect(
          env.container.read(formDraftsProvider).single.hasUnknownSubmission,
          isTrue,
        );
        await _close(tester, env);
        env = await _open(
          tester,
          api,
          storage,
          location: draft.resumeLocation,
          write: false,
          productionGuard: true,
        );
        await tapFinanceOriginalAction(tester, '核对原保存结果');
        await tester.pumpAndSettle();
        expect(api.commands, hasLength(1));
        expect(
          env.container.read(formDraftsProvider).single.hasUnknownSubmission,
          isFalse,
        );
        expect(_row(tester).amount.text, entered);
        expect(find.text('核对当前单据'), findsOneWidget);
        expect(api.cancellations.single['requestBody'], original);
        expect(api.cancellations.single['precisionChoices'], isEmpty);
        await _close(tester, env);
        env = await _open(
          tester,
          api,
          storage,
          location: draft.resumeLocation,
          productionGuard: true,
        );
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(find.text('采用当前版本，保留输入'), findsOneWidget);
        expect(api.commands, hasLength(1));
        await tester.tap(find.text('采用当前版本，保留输入'));
        await tester.pumpAndSettle();
        expect(_row(tester).amount.text, entered);
        expect(api.commands, hasLength(1));
        api.reject = false;
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(api.commands, hasLength(2));
        expect(api.commands.last['requestId'], isNot(original['requestId']));
        expect(
          api.commands.last['expectedSnapshot'],
          List.filled(64, 'b').join(),
        );
        expect(
          (((api.commands.last['document'] as Map)['items'] as List).single
              as Map)['amountOriginal'],
          entered,
        );
        expect(tester.takeException(), isNull);
        await _close(tester, env);
      },
    );
  }
}
