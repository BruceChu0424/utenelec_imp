import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/intake/sales_learning_status.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _key = (kind: 'quotes', documentId: 'quote');
Map<String, dynamic> _receipt({
  bool canRetry = true,
  String state = 'PARTIAL',
}) => {
  'id': 'receipt',
  'state': state,
  'message': state == 'SUCCEEDED' ? '已学成' : '部分待重试',
  'canRetry': canRetry,
  'payload': {'clientBank': 'secret'},
  'evidence': ['secret'],
  'steps': [
    {
      'kind': 'MASTER',
      'sourceIndex': 0,
      'status': state == 'SUCCEEDED' ? 'SUCCEEDED' : 'FAILED',
      'attempts': 1,
      'errorClass': 'TransientDataAccessException',
      'rawError': 'secret',
      'counts': {'aliases': 2, 'bank': 'secret'},
    },
  ],
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  final calls = <String>[];
  Object? body;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add('GET $path');
    return [_receipt()];
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    calls.add('POST $path');
    this.body = body;
    return [_receipt()];
  }
}

class _Repository extends SalesLearningRepository {
  _Repository() : super(_Api());
  int reads = 0, retries = 0;
  Object? failure;
  Completer<List<SalesLearningReceipt>>? retryResult;
  bool complete = false;
  bool canRetry = true;
  @override
  Future<List<SalesLearningReceipt>> list(SalesLearningKey key) async {
    reads++;
    if (failure != null) throw failure!;
    return [
      SalesLearningReceipt.fromJson(
        _receipt(
          canRetry: canRetry && !complete,
          state: complete ? 'SUCCEEDED' : 'PARTIAL',
        ),
      ),
    ];
  }

  @override
  Future<List<SalesLearningReceipt>> retry(
    SalesLearningKey key,
    String receiptId,
  ) async {
    retries++;
    final result = await retryResult?.future ?? <SalesLearningReceipt>[];
    complete = true;
    return result;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool readOnly = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        salesLearningRepositoryProvider.overrideWithValue(repository),
        authenticatedScopeProvider.overrideWithValue(
          AuthenticatedScope(userId: 'actor', readOnly: readOnly),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Scaffold(
          body: SalesLearningStatusPanel(kind: 'quotes', documentId: 'quote'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(SalesLearningStatusPanel)),
  );
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.text('自学习'));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'receipt and repository expose only status data and use document-scoped paths',
    () async {
      final api = _Api(), repository = SalesLearningRepository(_Api());
      expect(
        () => repository.path((kind: 'clients', documentId: 'id')),
        throwsArgumentError,
      );
      final real = SalesLearningRepository(api);
      final rows = await real.list(_key);
      await real.retry((kind: 'orders', documentId: 'order/id'), 'receipt/id');
      expect(api.calls, [
        'GET /sales/quotes/quote/learning',
        'POST /sales/orders/order%2Fid/learning/receipt%2Fid/retry',
      ]);
      expect(api.body, isEmpty);
      expect(rows.single.steps.single.keys, isNot(contains('rawError')));
      expect(rows.single.steps.single.toString(), isNot(contains('secret')));
    },
  );
  testWidgets(
    'forbidden receipts stay hidden; transient read failures can refresh',
    (tester) async {
      final repository = _Repository()
        ..failure = ApiException('FORBIDDEN', 'private');
      await _pump(tester, repository);
      expect(find.byKey(const ValueKey('sales-learning-status')), findsNothing);
      expect(find.text('private'), findsNothing);
      repository.failure = NetworkException();
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, repository);
      expect(find.text('学习记录暂时无法读取'), findsOneWidget);
      repository.failure = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sales-learning-status')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'read-only identity and server retry denial hide mutation actions',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository, readOnly: true);
      await _expand(tester);
      expect(
        find.byKey(const ValueKey('retry-learning-receipt')),
        findsNothing,
      );
      expect(find.textContaining('货品对照 2'), findsOneWidget);
      expect(find.textContaining('TransientDataAccessException'), findsNothing);
      repository.canRetry = false;
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, repository);
      await _expand(tester);
      expect(
        find.byKey(const ValueKey('retry-learning-receipt')),
        findsNothing,
      );
    },
  );
  testWidgets('retry is single flight and refreshes successful server state', (
    tester,
  ) async {
    final repository = _Repository()..retryResult = Completer();
    await _pump(tester, repository);
    await _expand(tester);
    await tester.tap(find.byKey(const ValueKey('retry-learning-receipt')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('retry-learning-receipt')));
    await tester.pump();
    expect(repository.retries, 1);
    repository.retryResult!.complete([]);
    await tester.pumpAndSettle();
    expect(repository.reads, 2);
    expect(find.text('已学成'), findsWidgets);
    expect(find.byKey(const ValueKey('retry-learning-receipt')), findsNothing);
  });
  testWidgets('failed retry shows safe error and preserves retry affordance', (
    tester,
  ) async {
    final repository = _Repository()..retryResult = Completer();
    final container = await _pump(tester, repository);
    await _expand(tester);
    await tester.tap(find.byKey(const ValueKey('retry-learning-receipt')));
    await tester.pump();
    repository.retryResult!.completeError(StateError('secret raw payload'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('retry-learning-receipt')),
      findsOneWidget,
    );
    expect(
      container.read(appNotificationProvider).single.message,
      '学习暂未完成，请稍后重试',
    );
    expect(repository.reads, 1);
  });
}
