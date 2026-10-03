import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/intake/finance_intake_launcher.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';

final _file = PlatformFile(
  name: 'bank.csv',
  size: 4,
  bytes: Uint8List.fromList([1, 2, 3, 4]),
);
Map<String, dynamic> _result({Map<String, String>? fields}) => {
  'docType': 'receipt',
  'source': {
    'fileName': _file.name,
    'sha256': sha256.convert(_file.bytes!).toString(),
  },
  'fields':
      fields ??
      {
        'bankReference': 'BANK-001',
        'accountAmount': '1234.56',
        'currencyCode': 'CNY',
        'bankFee': '2.00',
        'transactionDate': '2026-10-03',
      },
  'fieldSources': {'bankReference': 'bank!B2', 'accountAmount': 'bank!B3'},
  'warnings': <String>[],
};

Widget _app(Widget child, {Locale locale = const Locale('zh')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  test('source binds document type filename and exact immutable bytes', () {
    final result = FinanceIntakeResult.fromJson(_result());
    expect(result.matchesSource(_file, FinanceDocType.receipt), isTrue);
    expect(result.matchesSource(_file, FinanceDocType.payment), isFalse);
    expect(
      result.matchesSource(
        PlatformFile(name: 'renamed.csv', size: 4, bytes: _file.bytes),
        FinanceDocType.receipt,
      ),
      isFalse,
    );
    expect(
      result.matchesSource(
        PlatformFile(
          name: _file.name,
          size: 4,
          bytes: Uint8List.fromList([4, 3, 2, 1]),
        ),
        FinanceDocType.receipt,
      ),
      isFalse,
    );
  });

  test(
    'malformed amount date reference and currency cannot enter patch candidates',
    () {
      final result = FinanceIntakeResult.fromJson(
        _result(
          fields: {
            'accountAmount': '1e3',
            'bankFee': '-1.00',
            'transactionDate': '2026-02-30',
            'bankReference': '<script>',
            'currencyCode': 'UNKNOWN',
          },
        ),
      );
      expect(result.fields, isEmpty);
      final exact = FinanceIntakeResult.fromJson(
        _result(fields: {'accountAmount': '9007199254.99'}),
      );
      expect(exact.fields[FinanceIntakeField.accountAmount], '9007199254.99');
    },
  );

  for (final type in [FinanceDocType.receipt, FinanceDocType.payment]) {
    testWidgets(
      '$type fees and dates are reference only; replacements require selection',
      (tester) async {
        await tester.pumpWidget(
          _app(
            FinanceIntakeReviewDialog(
              result: FinanceIntakeResult.fromJson(_result()),
              docType: type,
              currentFields: const {FinanceIntakeField.accountAmount: '500.00'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        CheckboxListTile field(String key) =>
            tester.widget(find.byKey(ValueKey('finance-intake-field-$key')));
        expect(field('bankFee').onChanged, isNull);
        expect(field('transactionDate').onChanged, isNull);
        expect(field('accountAmount').value, isFalse);
        expect(find.textContaining('500.00 →'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('finance-intake-confirm')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('finance-intake-field-currencyCode')),
        );
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('finance-intake-confirm')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('finance-intake-field-accountAmount')),
        );
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('finance-intake-confirm')),
              )
              .onPressed,
          isNotNull,
        );
      },
    );
  }

  testWidgets('an amount without an explicit currency cannot be selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        FinanceIntakeReviewDialog(
          result: FinanceIntakeResult.fromJson(
            _result(fields: {'accountAmount': '100.00'}),
          ),
          docType: FinanceDocType.receipt,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('finance-intake-field-accountAmount')),
          )
          .onChanged,
      isNull,
    );
  });

  for (final locale in ['en', 'ko']) {
    testWidgets('$locale displays localized review and warnings', (
      tester,
    ) async {
      final json = _result()..['warnings'] = ['文件出现与当前收付款方向不一致的金额，请核对用途后手工填写'];
      await tester.pumpWidget(
        _app(
          FinanceIntakeReviewDialog(
            result: FinanceIntakeResult.fromJson(json),
            docType: FinanceDocType.receipt,
          ),
          locale: Locale(locale),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(locale == 'en' ? 'Review bank document' : '은행 자료 확인'),
        findsOneWidget,
      );
      expect(find.textContaining('文件出现'), findsNothing);
    });
  }

  testWidgets(
    'confirm rereads owner job and preserves unselected source currency',
    (tester) async {
      final repo = _Jobs();
      FinanceIntakePatch? patch;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [aiJobRepositoryProvider.overrideWithValue(repo)],
          child: _app(
            Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async {
                  patch = await launchFinanceIntakeWithFile(
                    context,
                    ref,
                    file: _file,
                    docType: FinanceDocType.receipt,
                    stillCurrent: () => true,
                  );
                },
                child: const Text('start'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('finance-intake-field-accountAmount')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('finance-intake-confirm')));
      await tester.pumpAndSettle();
      expect(repo.reads, 1);
      expect(patch?.accountAmount, '1234.56');
      expect(patch?.currencyCode, isNull);
      expect(patch?.sourceCurrencyCode, 'CNY');
      expect(patch?.bankFee, isNull);
      expect(patch?.transactionDate, isNull);
      expect(() => patch!.file.bytes![0] = 7, throwsUnsupportedError);
    },
  );

  testWidgets(
    'a late confirmation result cannot apply after caller fence changes',
    (tester) async {
      final pending = Completer<AiJobSnapshot>();
      final repo = _Jobs()..nextRead = () => pending.future;
      var current = true;
      FinanceIntakePatch? patch;
      var finished = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [aiJobRepositoryProvider.overrideWithValue(repo)],
          child: _app(
            Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async {
                  patch = await launchFinanceIntakeWithFile(
                    context,
                    ref,
                    file: _file,
                    docType: FinanceDocType.receipt,
                    stillCurrent: () => current,
                  );
                  finished = true;
                },
                child: const Text('start'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('finance-intake-field-bankReference')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('finance-intake-confirm')));
      await tester.pumpAndSettle();
      expect(repo.reads, 1);
      current = false;
      pending.complete(repo.snapshot());
      await tester.pumpAndSettle();
      expect(finished, isTrue);
      expect(patch, isNull);
    },
  );

  testWidgets('revocation during confirmation prevents a patch', (
    tester,
  ) async {
    final repo = _Jobs()
      ..nextRead = () => Future.error(ApiException('FORBIDDEN', 'revoked'));
    Object? error;
    FinanceIntakePatch? patch;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [aiJobRepositoryProvider.overrideWithValue(repo)],
        child: _app(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async {
                try {
                  patch = await launchFinanceIntakeWithFile(
                    context,
                    ref,
                    file: _file,
                    docType: FinanceDocType.receipt,
                    stillCurrent: () => true,
                  );
                } catch (e) {
                  error = e;
                }
              },
              child: const Text('start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('finance-intake-field-bankReference')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('finance-intake-confirm')));
    await tester.pumpAndSettle();
    expect(patch, isNull);
    expect(error, isA<ApiException>());
  });
}

class _Jobs implements AiJobRepository {
  int reads = 0;
  Future<AiJobSnapshot> Function()? nextRead;
  AiJobSnapshot snapshot() => AiJobSnapshot(
    id: '11111111-1111-4111-8111-111111111111',
    kind: financeIntakeKind,
    status: AiJobStatus.succeeded,
    result: _result(),
  );
  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async => snapshot();
  @override
  Future<AiJobSnapshot> get(String jobId) {
    reads++;
    return nextRead?.call() ?? Future.value(snapshot());
  }

  @override
  Future<void> cancel(String jobId) async {}
}
