// Actual guided widgets with synthetic values. Opt-in PNG capture, no business services.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/widgets/expense_guided_invoice_preview.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_banner.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_plan.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import 'ai_visual_support.dart';

void main() {
  for (final width in [390.0, 1000.0]) {
    testWidgets('guided source and progress fit width $width', (tester) async {
      await setCaptureView(tester, Size(width, 1000));
      final bytes = Uint8List.fromList([1, 2, 3]);
      const identity = (
        scope: AuthenticatedScope(userId: 'visual-fixture'),
        server: 'https://fixture.invalid',
        permissions: 'expense:apply',
      );
      final plan = AiGuidedFilePlan(
        jobId: '11111111-1111-4111-8111-111111111111',
        file: PlatformFile(
          name: '办公用品电子发票（示例）.pdf',
          size: bytes.length,
          bytes: bytes,
        ),
        identity: identity,
        workflow: AiGuidedWorkflow.expenseClaim,
        result: AiGuidedFileResult.fromJson({
          'workflow': 'EXPENSE_CLAIM',
          'needsChoice': false,
          'requiresReview': true,
          'source': {
            'fileName': '办公用品电子发票（示例）.pdf',
            'sha256': sha256.convert(bytes).toString(),
          },
          'fields': {
            'invoiceType': 'DIGITAL',
            'invoiceNo': '26999900000012345678',
            'issueDate': '2026-10-03',
            'sellerName': '示例办公用品有限公司',
            'amountExclTax': '100.00',
            'taxAmount': '13.00',
            'totalAmount': '113.00',
          },
        }),
      );
      await tester.pumpWidget(
        captureApp(
          overrides: [aiGuidedFileIdentityProvider.overrideWithValue(identity)],
          home: Scaffold(
            appBar: AppBar(title: const Text('文件辅助填写 · 组件核对')),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AiGuidedFileBanner(
                    plan: plan,
                    status: 'guidedFilled',
                    completedStages: const [
                      'guidedParsing',
                      'guidedHeader',
                      'guidedRows',
                    ],
                    activeStage: 'guidedManualSave',
                    filledFields: const ['办公用品', '价税合计：113.00'],
                  ),
                  ExpenseGuidedInvoicePreview(plan: plan),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-guided-file-progress')),
        findsOneWidget,
      );
      expect(find.text('等待你手动保存'), findsOneWidget);
      await capture(tester, 'guided-source-${width.toInt()}');
    }, skip: !kCaptureUi);
  }
}
