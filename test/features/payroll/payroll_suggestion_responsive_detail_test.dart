import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/models/payroll_batch.dart';
import 'package:uten_imp/features/payroll/pages/payroll_generate_page.dart';
import 'package:uten_imp/features/payroll/pages/payroll_slip_detail_page.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
import 'package:uten_imp/features/suggestion/models/suggestion.dart';
import 'package:uten_imp/features/suggestion/pages/suggestion_detail_page.dart';
import 'package:uten_imp/features/suggestion/pages/suggestion_new_page.dart';
import 'package:uten_imp/features/suggestion/providers/suggestion_providers.dart';
import 'package:uten_imp/features/suggestion/repositories/suggestion_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _name = '这是一个需要完整保留而不能挤掉提交日期的员工姓名';

class _Payroll extends Fake implements PayrollRepository {
  final viewed = <String>[];
  final reads = <String>[];

  @override
  Future<PayrollSlip> getSlip(String id) async {
    reads.add(id);
    return const PayrollSlip(
      id: 'slip-1',
      employeeId: 'employee-1',
      employeeName: _name,
      employeeCode: 'EMP00000000000000001',
      year: 2026,
      month: 10,
      items: [],
      grossIncome: 9876543211.12,
      totalDeduction: 1,
      netIncome: 9876543210.12,
      status: PayrollSlipStatus.published,
      publishedAt: null,
    );
  }

  @override
  Future<PayrollSlip?> markViewed(String id) async {
    viewed.add(id);
    return null;
  }

  @override
  Future<List<PayrollDepartmentOption>> listDepartmentOptions() async => [];
}

class _Suggestions extends Fake implements SuggestionRepository {
  final likes = <String>[];
  Suggestion get row => Suggestion(
    id: 'suggestion-1',
    submitterId: 'employee-1',
    submitterName: _name,
    category: SuggestionCategory.environment,
    title: '完整的建议标题与提交人',
    content: '正文需要可读而且保持原点赞操作。',
    status: SuggestionStatus.submitted,
    submittedAt: DateTime(2026, 10, 13, 8, 35),
    likes: 9999999 + likes.length,
    likedByMe: likes.isNotEmpty,
    replies: [
      SuggestionReply(
        id: 'reply-1',
        replier: '很长的官方回复人员姓名',
        replierRole: 'HR',
        content: '完整的官方回复内容',
        repliedAt: DateTime(2026, 10, 13, 9),
      ),
    ],
  );

  @override
  Future<Suggestion?> getById(String id) async => row;

  @override
  Future<PagedResult<Suggestion>> list({
    bool mine = false,
    SuggestionCategory? category,
    SuggestionStatus? status,
    int page = 1,
    int size = 20,
  }) async => PagedResult(
    items: [row],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<Suggestion> toggleLike(String id) async {
    likes.add(id);
    return row;
  }
}

void main() {
  for (final systemText in [1.0, 2.0]) {
    testWidgets(
      '200% payroll preserves large amount and one view receipt system=$systemText',
      (tester) async {
        final payroll = _Payroll();
        final preferences = await _preferences();
        await _pump(
          tester,
          const PayrollSlipDetailPage(slipId: 'slip-1'),
          preferences: preferences,
          payroll: payroll,
          systemText: systemText,
        );
        final summary = find.byKey(
          const ValueKey('payroll-slip-summary-slip-1'),
        );
        expect(summary, findsOneWidget);
        const exactAmount = '9876543210.12 元';
        final amount = find.descendant(
          of: summary,
          matching: find.text(exactAmount),
        );
        expect(amount, findsOneWidget);
        await Scrollable.ensureVisible(tester.element(amount), alignment: 0.5);
        await tester.pumpAndSettle();
        final amountContext = tester.element(amount);
        final expectedStyle = Theme.of(amountContext).textTheme.titleLarge!;
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: amount, matching: find.byType(RichText)),
        );
        expect(paragraph.text.toPlainText(), exactAmount);
        expect(paragraph.text.style!.fontSize, expectedStyle.fontSize);
        expect(paragraph.text.style!.fontWeight, FontWeight.w700);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(paragraph.maxLines, isNull);
        expect(
          paragraph.textScaler.scale(expectedStyle.fontSize!),
          closeTo(expectedStyle.fontSize! * systemText, 0.001),
        );
        expect(UtenDisplayScale.fontZoomOf(amountContext), 2);
        expect(
          find.ancestor(of: amount, matching: find.byType(FittedBox)),
          findsNothing,
          reason: 'the complete amount must wrap without shrinking its font',
        );
        final amountRect = tester.getRect(amount);
        expect(amountRect.top, greaterThanOrEqualTo(-0.05));
        expect(amountRect.bottom, lessThanOrEqualTo(1200 + 0.05));
        final glyphBoxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: exactAmount.length),
        );
        expect(glyphBoxes, isNotEmpty);
        for (final box in glyphBoxes) {
          expect(box.left, greaterThanOrEqualTo(-0.05));
          expect(box.right, lessThanOrEqualTo(paragraph.size.width + 0.05));
          expect(box.top, greaterThanOrEqualTo(-0.05));
          expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 0.05));
        }
        expect(payroll.reads, ['slip-1']);
        expect(payroll.viewed, ['slip-1']);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '200% suggestion keeps long identity, date and real like system=$systemText',
      (tester) async {
        final suggestions = _Suggestions();
        final preferences = await _preferences();
        await _pump(
          tester,
          const SuggestionDetailPage(suggestionId: 'suggestion-1'),
          preferences: preferences,
          suggestions: suggestions,
          systemText: systemText,
        );
        expect(find.text(_name), findsOneWidget);
        final pageScroll = Scrollable.of(
          tester.element(find.text('完整的建议标题与提交人')),
          axis: Axis.vertical,
        );
        final scrollable = find.byElementPredicate(
          (element) =>
              element is StatefulElement &&
              identical(element.state, pageScroll),
        );
        await tester.scrollUntilVisible(
          find.text('2026-10-13 08:35'),
          240,
          scrollable: scrollable,
        );
        expect(find.text('2026-10-13 08:35'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('suggestion-reply-submit')),
          findsNothing,
          reason: 'the responsive layout must retain the reply permission',
        );
        await tester.scrollUntilVisible(
          find.byIcon(Icons.favorite_border_rounded),
          240,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.favorite_border_rounded));
        await tester.pumpAndSettle();
        expect(suggestions.likes, ['suggestion-1']);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '200% payroll year/month remain full fields system=$systemText',
      (tester) async {
        final payroll = _Payroll();
        await _pump(
          tester,
          const PayrollGeneratePage(),
          preferences: await _preferences(),
          payroll: payroll,
          systemText: systemText,
        );
        final year = find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '工资年份',
        );
        final month = find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '工资月份',
        );
        expect(year, findsOneWidget);
        expect(month, findsOneWidget);
        expect(
          tester.getTopLeft(month).dy,
          greaterThan(tester.getTopLeft(year).dy),
        );
        expect(payroll.viewed, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '200% suggestion anonymous control remains usable system=$systemText',
      (tester) async {
        await _pump(
          tester,
          const SuggestionNewPage(),
          preferences: await _preferences(),
          suggestions: _Suggestions(),
          systemText: systemText,
        );
        final pageScroll = Scrollable.of(
          tester.element(find.text('建议类别')),
          axis: Axis.vertical,
        );
        await tester.scrollUntilVisible(
          find.byType(Switch).hitTestable(),
          240,
          scrollable: find.byElementPredicate(
            (element) =>
                element is StatefulElement &&
                identical(element.state, pageScroll),
          ),
        );
        expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<SharedPreferences> _preferences() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  required SharedPreferences preferences,
  _Payroll? payroll,
  _Suggestions? suggestions,
  required double systemText,
}) async {
  tester.view.physicalSize = const Size(320, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({}),
        if (payroll != null)
          payrollRepositoryProvider.overrideWithValue(payroll),
        if (suggestions != null)
          suggestionRepositoryProvider.overrideWithValue(suggestions),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(systemText)),
          child: UtenDisplayZoomBox(fontFactor: 2, child: child!),
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
