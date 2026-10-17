import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/features/expense/widgets/expense_claim_print.dart';
import 'package:uten_imp/features/production/models/daily_report_material_review.dart';
import 'package:uten_imp/features/production/widgets/daily_report_material_review_section.dart';

void main() {
  testWidgets(
    'daily material review copies displayed text and keeps decision data unchanged',
    (tester) async {
      const review = DailyReportMaterialReview(
        reportId: 'report-1',
        reportVersion: 3,
        fingerprint: 'snapshot-1',
        rows: [
          DailyReportMaterialReviewRow(
            demandId: 'demand-1',
            planId: 'plan-1',
            materialExecutionSegmentId: 'segment-1',
            materialExecutionSegmentCode: 'WO-001',
            goodsCode: 'G001',
            goodsName: 'MATERIAL-01',
            unitName: '个',
            availableQty: '12',
            usageQty: '4',
            remainingIssuedQty: '8',
            undrawnDirectQty: '0',
            returnableIssuedQty: '8',
            returnableDirectQty: '0',
            canReturn: true,
          ),
        ],
      );
      final actions = {'demand-1': DailyReportMaterialAction.keep};
      var changes = 0;
      await _pump(
        tester,
        ListView(
          children: [
            DailyReportMaterialReviewSection(
              review: review,
              actions: actions,
              editable: true,
              historical: false,
              expanded: true,
              onExpandedChanged: (_) {},
              onChanged: (_, _) => changes++,
              onRefresh: () {},
            ),
          ],
        ),
      );

      expect(await _dragAndCopy(tester, 'MATERIAL-01'), 'MATERIAL-01');
      expect(changes, 0);
      expect(actions, {'demand-1': DailyReportMaterialAction.keep});
      expect(review.rows.single.remainingIssuedQty, '8');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'generic paper preview copies a cell with no page selection ancestor',
    (tester) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showUtenPrintPreview(
              context: context,
              title: 'Copy preview',
              loader: () async => const UtenPrintTable(
                headers: ['Code'],
                rows: [
                  ['PREVIEW-COPY-123'],
                ],
              ),
            ),
            child: const Text('Open preview'),
          ),
        ),
      );
      await tester.tap(find.text('Open preview'));
      await tester.pumpAndSettle();
      expect(
        await _dragAndCopy(tester, 'PREVIEW-COPY-123'),
        'PREVIEW-COPY-123',
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'expense paper preview copies the original projected description',
    (tester) async {
      final claim = ExpenseClaim(
        id: 'claim-1',
        claimNo: 'BX001',
        applicantId: 'employee-1',
        applicantName: 'Employee',
        title: 'Travel',
        items: [
          ExpenseItem(
            id: 'item-1',
            category: ExpenseCategory.transport,
            amount: 12.5,
            date: DateTime.utc(2026, 10, 17),
            description: 'EXPENSE-COPY-123',
          ),
        ],
        totalAmount: 12.5,
        status: ExpenseClaimStatus.draft,
        createdAt: DateTime.utc(2026, 10, 17),
      );
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showExpenseClaimPrintPreview(context, claim),
            child: const Text('Open expense'),
          ),
        ),
      );
      await tester.tap(find.text('Open expense'));
      await tester.pumpAndSettle();
      expect(
        await _dragAndCopy(tester, 'EXPENSE-COPY-123'),
        'EXPENSE-COPY-123',
      );
      expect(claim.items.single.description, 'EXPENSE-COPY-123');
      expect(claim.totalAmount, 12.5);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );
}

Future<void> _pump(WidgetTester tester, Widget body) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        expenseSettingsProvider.overrideWith(
          (_) async => const ExpenseSettings(companyName: 'UTEN'),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => UtenContextMenuPolicy(child: child!),
        home: Scaffold(body: body),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Select actual glyph bounds, then verify the platform clipboard command.
Future<String?> _dragAndCopy(WidgetTester tester, String text) async {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final finder = find.text(text);
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: finder, matching: find.byType(RichText)),
  );
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  final first = boxes.first;
  final last = boxes.last;
  final start = paragraph.localToGlobal(
    Offset(first.left + 1, (first.top + first.bottom) / 2),
  );
  final end = paragraph.localToGlobal(
    Offset(last.right + 2, (last.top + last.bottom) / 2),
  );
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveTo(end);
  await gesture.up();
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  return copied;
}
