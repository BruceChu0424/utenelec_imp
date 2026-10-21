import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/widgets/finance_document_unapproval_action.dart';
import 'package:uten_imp/shared/documents/document_unapproval.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/native_detail_reader_overrides.dart';

class _Reader extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'a', code: 'A', name: '财务A'),
  );
  void switchIdentity() => state = const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'b', code: 'B', name: '财务B'),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  int posts = 0;
  String? postedPath;
  Object? postedBody;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'supported': true,
    'permitted': true,
    'eligible': true,
    'nextAction': 'UNAPPROVE_TO_DRAFT',
    'factsSnapshot': 'a' * 64,
    'reasons': <Object>[],
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts++;
    postedPath = path;
    postedBody = body;
    return {'id': 'successor', 'unapprovalOriginalId': 'original', 'status': 0};
  }
}

void main() {
  testWidgets(
    'pushed reversal opens its successor with detail source and without history',
    (tester) async {
      final api = _Api();
      final (router, _) = await _pumpRoutes(tester, api);
      await tester.tap(find.text('反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 0);
      await tester.tap(find.widgetWithText(TextButton, '确认反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 1);
      expect(api.postedPath, '/documents/financeExpense/original/unapprove');
      expect((api.postedBody as Map)['expectedSnapshot'], 'a' * 64);
      final uri = GoRouterState.of(
        tester.element(find.byKey(const ValueKey('finance-page-successor'))),
      ).uri;
      expect(uri.path, '/finance/expenses/successor');
      expect(uri.queryParameters, {
        'returnTo': '/finance/expenses',
        'tab': 'attachments',
      });
      expect(find.byKey(const ValueKey('finance-page-original')), findsNothing);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('finance-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an offstage reversal callback cannot replace a different active detail',
    (tester) async {
      final (router, contexts) = await _pumpRoutes(tester, _Api());
      router.push('/finance/expenses/other?tab=other');
      await tester.pumpAndSettle();
      openUnapprovedDraft(contexts['original']!, '/finance/expenses/successor');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('finance-page-other')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('finance-page-successor')),
        findsNothing,
      );
      expect(
        GoRouterState.of(contexts['other']!).uri.queryParameters['tab'],
        'other',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a dialog cannot borrow its host document identity for successor navigation',
    (tester) async {
      final (_, contexts) = await _pumpRoutes(tester, _Api());
      showDialog<void>(
        context: contexts['original']!,
        builder: (context) => AlertDialog(
          content: TextButton(
            onPressed: () =>
                openUnapprovedDraft(context, '/finance/expenses/successor'),
            child: const Text('弹层跳转'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('弹层跳转'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('finance-page-successor')),
        findsNothing,
      );
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('finance-page-original')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finance history confirmation uses the shared snapshot-bound successor transaction',
    (tester) async {
      final api = _Api();
      var completed = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeDetailReaderOverrides(includeSession: false),
            sessionProvider.overrideWith(_Reader.new),
            apiClientProvider.overrideWithValue(api),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FinanceDocumentUnapprovalAction(
                family: 'salesOrder',
                documentId: 'original',
                revision: 'r1',
                onCompleted: () => completed++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 0);
      await tester.tap(find.widgetWithText(TextButton, '确认反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 1);
      expect(api.postedPath, '/documents/salesOrder/original/unapprove');
      expect((api.postedBody as Map)['expectedSnapshot'], 'a' * 64);
      expect(completed, 1);
    },
  );
  testWidgets(
    'finance history reversal cannot submit after identity changes in its confirmation',
    (tester) async {
      final api = _Api();
      var completed = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...nativeDetailReaderOverrides(includeSession: false),
            sessionProvider.overrideWith(_Reader.new),
            apiClientProvider.overrideWithValue(api),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FinanceDocumentUnapprovalAction(
                family: 'purchaseOrder',
                documentId: 'original',
                revision: 'r1',
                onCompleted: () => completed++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('反审'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FinanceDocumentUnapprovalAction)),
      );
      (container.read(sessionProvider.notifier) as _Reader).switchIdentity();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '确认反审'));
      await tester.pumpAndSettle();
      expect(api.posts, 0);
      expect(completed, 0);
    },
  );
}

Future<(GoRouter, Map<String, BuildContext>)> _pumpRoutes(
  WidgetTester tester,
  _Api api,
) async {
  final contexts = <String, BuildContext>{};
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
          key: const ValueKey('finance-list'),
          body: TextButton(
            onPressed: () => context.push(
              '/finance/expenses/original?history=1'
              '&returnTo=%2Ffinance%2Fexpenses&tab=attachments',
            ),
            child: const Text('原单据详情'),
          ),
        ),
      ),
      GoRoute(
        path: '/finance/expenses/:id',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          contexts[id] = context;
          return Scaffold(
            key: ValueKey('finance-page-$id'),
            body: id == 'original'
                ? FinanceDocumentUnapprovalAction(
                    family: 'financeExpense',
                    documentId: id,
                    revision: 'r1',
                    onCompleted: () => openUnapprovedDraft(
                      context,
                      '/finance/expenses/successor',
                    ),
                  )
                : Text(id),
          );
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(includeSession: false),
        sessionProvider.overrideWith(_Reader.new),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('费用列表'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('原单据详情'));
  await tester.pumpAndSettle();
  return (router, contexts);
}
