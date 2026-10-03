import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_en.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_banner.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_plan.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  final l10n = AppLocalizationsEn();

  testWidgets('filled banner shows values and one next step without rules', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text(l10n.aiChatGuidedFilled), findsOneWidget);
    expect(find.text(l10n.aiChatDocumentManualSave), findsOneWidget);
    expect(find.text(l10n.aiChatGuidedParsing), findsNothing);
    expect(find.text(l10n.aiChatGuidedNoMasterWrites), findsNothing);
    expect(find.text(l10n.aiChatBoundary), findsNothing);
    expect(find.text('113.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved banner does not claim the expense remains unsaved', (
    tester,
  ) async {
    await _pump(
      tester,
      status: 'guidedExpenseSaved',
      activeStage: 'guidedInvoiceRegister',
    );
    expect(find.text(l10n.aiChatGuidedExpenseSaved), findsOneWidget);
    expect(find.text(l10n.aiChatGuidedInvoiceRegister), findsOneWidget);
    expect(find.text(l10n.aiChatDocumentManualSave), findsNothing);
  });

  testWidgets('failure detail and retry remain visible', (tester) async {
    await _pump(
      tester,
      status: 'guidedWaiting',
      activeStage: 'guidedWaiting',
      detail: l10n.aiChatDocumentSourceMismatch,
    );
    expect(find.text(l10n.aiChatDocumentSourceMismatch), findsOneWidget);
    expect(find.text(l10n.aiChatRetry), findsOneWidget);
    expect(find.text(l10n.aiChatDocumentManualSave), findsNothing);
  });

  testWidgets('observed progress fits narrow width at double text size', (
    tester,
  ) async {
    await _pump(
      tester,
      status: 'guidedFilling',
      activeStage: 'guidedRows',
      busy: true,
      scale: 2,
    );
    expect(find.text(l10n.aiChatGuidedParsing), findsOneWidget);
    expect(find.text(l10n.aiChatGuidedRows), findsOneWidget);
    expect(find.text(l10n.aiChatDocumentManualSave), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  String status = 'guidedFilled',
  String activeStage = 'guidedManualSave',
  String? detail,
  bool busy = false,
  double scale = 1,
}) async {
  const identity = (
    scope: AuthenticatedScope(userId: 'banner-fixture'),
    server: 'https://fixture.invalid',
    permissions: 'expense:apply',
  );
  final bytes = Uint8List.fromList([1, 2, 3]);
  final plan = AiGuidedFilePlan(
    jobId: 'banner-job',
    file: PlatformFile(name: 'invoice.pdf', size: bytes.length, bytes: bytes),
    identity: identity,
    workflow: AiGuidedWorkflow.expenseClaim,
    result: AiGuidedFileResult.fromJson({
      'workflow': 'EXPENSE_CLAIM',
      'source': {
        'fileName': 'invoice.pdf',
        'sha256': sha256.convert(bytes).toString(),
      },
    }),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [aiGuidedFileIdentityProvider.overrideWithValue(identity)],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: AiGuidedFileBanner(
                  plan: plan,
                  status: status,
                  activeStage: activeStage,
                  busy: busy,
                  detail: detail,
                  onRetry: detail == null ? null : () {},
                  completedStages: const ['guidedParsing', 'guidedHeader'],
                  filledFields: const ['113.00'],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
