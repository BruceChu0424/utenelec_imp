import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template_learning.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../intake/sales_intake_test_support.dart';

class _Repository extends SalesQuoteTemplateRepository {
  _Repository() : super(ApiClient(Dio()));
  Completer<Map<String, dynamic>>? contextResult;
  final adopted = <String>[];
  Map<String, String>? confirmedRoles;
  @override
  Future<Map<String, dynamic>> learningContext(String quoteId) async =>
      contextResult == null
      ? {'clientId': 'customer-a', 'clientName': '客户甲'}
      : await contextResult!.future;
  @override
  Future<SalesQuoteTemplate> adopt(
    String quoteId,
    String jobId, {
    Map<String, String>? columnRoles,
  }) async {
    adopted.add('$quoteId:$jobId');
    confirmedRoles = columnRoles;
    return const SalesQuoteTemplate(id: 'template-a', name: '客户模板', version: 3);
  }
}

void main() {
  setUp(() => FilePicker.platform = FakeFilePicker(null));
  const result = {
    'templateOnly': true,
    'sheetName': 'Quote',
    'mapping': {
      'roles': {'A': 'PART_NO', 'B': 'QTY'},
      'roleHeaders': {'A': 'Model', 'B': 'Qty'},
    },
  };
  final scope = StateProvider<AuthenticatedScope?>(
    (ref) => const AuthenticatedScope(userId: 'a', epoch: 1),
  );
  final server = StateProvider<String>((ref) => 'https://company-a.invalid');

  Future<ProviderContainer> open(
    WidgetTester tester,
    _Repository repository,
    FakeAiJobRunner runner,
    void Function(SalesQuoteTemplate?) completed,
  ) async {
    final picker = FakeFilePicker(fakeFile('customer.xlsx'));
    final original = FilePicker.platform;
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = original);
    final presenter = FakeProgressPresenter();
    final container = ProviderContainer(
      overrides: [
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(scope)),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(server)),
        currentPermissionsProvider.overrideWithValue({
          Perm.salesQuoteView,
          Perm.salesQuoteExport,
          Perm.salesOrderPriceView,
          Perm.salesQuoteEdit,
        }),
        salesQuoteTemplateRepositoryProvider.overrideWithValue(repository),
        aiJobRunnerProvider.overrideWithValue(runner),
        salesIntakeProgressPresenterProvider.overrideWithValue(
          presenterOf(presenter),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async => completed(
                  await learnSalesQuoteTemplate(context, ref, 'quote-a'),
                ),
                child: const Text('开始'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'account switch while loading client context prevents file submission',
    (tester) async {
      final repository = _Repository()..contextResult = Completer();
      final runner = FakeAiJobRunner(result: result);
      bool done = false;
      final container = await open(tester, repository, runner, (value) {
        expect(value, isNull);
        done = true;
      });
      container.read(scope.notifier).state = const AuthenticatedScope(
        userId: 'b',
        epoch: 2,
      );
      await tester.pump();
      container.read(scope.notifier).state = const AuthenticatedScope(
        userId: 'a',
        epoch: 1,
      );
      await tester.pump();
      repository.contextResult!.complete({
        'clientId': 'customer-a',
        'clientName': '客户甲',
      });
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(runner.requests, isEmpty);
      expect(repository.adopted, isEmpty);
    },
  );

  testWidgets(
    'server switch clears an open customer mapping and prevents adoption',
    (tester) async {
      final repository = _Repository();
      final runner = FakeAiJobRunner(result: result);
      bool done = false;
      final container = await open(tester, repository, runner, (value) {
        expect(value, isNull);
        done = true;
      });
      expect(
        find.byKey(const ValueKey('quote-template-adopt')),
        findsOneWidget,
      );
      container.read(server.notifier).state = 'https://company-b.invalid';
      await tester.pumpAndSettle();
      expect(find.textContaining('客户甲'), findsNothing);
      expect(done, isTrue);
      expect(repository.adopted, isEmpty);
    },
  );

  testWidgets(
    'confirmation adopts the server job only and retains its exact version',
    (tester) async {
      final repository = _Repository();
      final runner = FakeAiJobRunner(result: result);
      SalesQuoteTemplate? saved;
      await open(tester, repository, runner, (value) => saved = value);
      expect(repository.adopted, isEmpty);
      await tester.tap(find.byKey(const ValueKey('quote-template-adopt')));
      await tester.pumpAndSettle();
      expect(repository.adopted, ['quote-a:job-42']);
      expect(repository.confirmedRoles, {'A': 'PART_NO', 'B': 'QTY'});
      expect(saved!.version, 3);
      expect(
        runner.lastRequest!.params,
        containsPair('templateAttemptId', isNotEmpty),
      );
      expect(Map.of(runner.lastRequest!.params)..remove('templateAttemptId'), {
        'docType': 'quote',
        'docId': 'quote-a',
        'clientId': 'customer-a',
        'templateOnly': 'true',
      });
    },
  );
}
