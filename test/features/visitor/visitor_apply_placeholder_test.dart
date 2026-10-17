import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/visitor/pages/visitor_apply_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'an unselected visit time is an empty named field and cancellation keeps it empty',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: VisitorApplyPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is InputDecorator &&
            widget.decoration.prefixIcon is Icon &&
            (widget.decoration.prefixIcon! as Icon).icon == Icons.event_rounded,
      );
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      final before = tester.widget<InputDecorator>(field);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(VisitorApplyPage)),
      );
      expect(before.isEmpty, isTrue);
      expect(before.child, isNull);
      expect(before.decoration.hintText, l10n.visitorApplyVisitTime);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(tester.widget<InputDecorator>(field).isEmpty, isTrue);
      expect(tester.widget<InputDecorator>(field).child, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
