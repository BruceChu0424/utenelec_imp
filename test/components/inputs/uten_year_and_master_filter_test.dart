import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/components/inputs/uten_selected_value_theme.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_year_selection_button.dart';
import 'package:uten_imp/components/inputs/uten_filter_field_theme.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_master_picker.dart';

void main() {
  for (final width in [1440.0, 375.0]) {
    testWidgets(
      'year picker cancels and reopens, selected filter matches search at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await loadAuditScreenshotFonts(tester);
        }
        var year = 2026;
        var changes = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: (width == 375 ? buildDarkTheme() : buildLightTheme())
                .copyWith(platform: TargetPlatform.windows),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            builder: (context, child) =>
                RepaintBoundary(key: capture, child: child!),
            home: StatefulBuilder(
              builder: (context, update) => Scaffold(
                body: UtenControlTheme(
                  child: SizedBox(
                    width: 320,
                    child: Column(
                      children: [
                        const UtenSearchBar(
                          key: ValueKey('search'),
                          compactIcon: false,
                        ),
                        UtenFilterFieldTheme(
                          child: UtenSelectedValueTheme(
                            child: UtenMasterPickerField<String>(
                              key: const ValueKey('party'),
                              initialId: 'party',
                              initialName: '已选择客户',
                              label: '客户',
                              icon: Icons.storefront_outlined,
                              idOf: (value) => value,
                              nameOf: (value) => value,
                              onChanged: (_) {},
                              onPick: () async => null,
                            ),
                          ),
                        ),
                        UtenYearSelectionButton(
                          year: year,
                          onChanged: (value) => update(() {
                            year = value;
                            changes++;
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('party')),
            matching: find.byType(TextField),
          ),
        );
        expect(field.decoration!.filled, isTrue);
        final border = find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.foregroundPainter?.runtimeType.toString() ==
                  '_InputBorderPainter',
        );
        Rect outline(String key) => tester.getRect(
          find.descendant(of: find.byKey(ValueKey(key)), matching: border),
        );
        expect(outline('party').height, closeTo(outline('search').height, .5));
        expect(
          outline('party').height,
          greaterThanOrEqualTo(
            UtenFilterRow.heightOf(
              tester.element(find.byKey(const ValueKey('party'))),
            ),
          ),
        );
        await tester.tap(find.text('2026'));
        await tester.pumpAndSettle();
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await saveAuditScreenshot(
            tester,
            capture,
            'year-selector-${width.toInt()}',
          );
        }
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(changes, 0);
        await tester.tap(find.text('2026'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey<int>(2025)));
        await tester.pumpAndSettle();
        expect(year, 2025);
        expect(changes, 1);
        expect(find.text('2025'), findsOneWidget);
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await saveAuditScreenshot(
            tester,
            capture,
            'selected-filter-${width.toInt()}',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
