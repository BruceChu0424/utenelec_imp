import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_date_range_selection_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/feedback/uten_date_range_tooltip.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';

Widget _app({
  required Widget child,
  TargetPlatform platform = TargetPlatform.windows,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  locale: const Locale('zh'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('touch long press reads dates without opening the calendar', (
    tester,
  ) async {
    var changes = 0;
    await tester.pumpWidget(
      _app(
        platform: TargetPlatform.android,
        child: UtenDateRangeSelectionButton(
          from: DateTime(2024),
          to: DateTime(2024, 1, 31),
          onChanged: (_, _) => changes++,
        ),
      ),
    );
    expect(find.byType(Icon), findsNothing);
    await tester.longPress(find.text('共31天'));
    await tester.pumpAndSettle();
    expect(find.text('2024.01.01-2024.01.31'), findsOneWidget);
    expect(find.byType(UtenDateRangePickerDialog), findsNothing);
    expect(changes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid Tab departure cannot publish a queued date tooltip', (
    tester,
  ) async {
    final dates = FocusNode();
    final next = FocusNode();
    addTearDown(dates.dispose);
    addTearDown(next.dispose);
    await tester.pumpWidget(
      _app(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenDateRangeTooltip(
              message: '2024.01.01-2024.01.31',
              child: TextButton(
                focusNode: dates,
                onPressed: () {},
                child: const Text('共31天'),
              ),
            ),
            TextButton(
              focusNode: next,
              onPressed: () {},
              child: const Text('下一项'),
            ),
          ],
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.idle();
    expect(dates.hasFocus, isTrue);
    // Keep the first focus callback queued until after the next Tab settles.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.idle();
    expect(next.hasFocus, isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('2024.01.01-2024.01.31'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow large text keeps date and clear targets aligned', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        platform: TargetPlatform.android,
        textScale: 2,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              UtenDateRangeSelectionButton(
                buttonKey: const Key('narrow-date'),
                from: DateTime(2024),
                to: DateTime(2024, 1, 31),
                onChanged: (_, _) {},
                onClear: () {},
              ),
              UtenButton(
                key: const Key('narrow-action'),
                onPressed: () {},
                child: const Text('刷新'),
              ),
            ],
          ),
        ),
      ),
    );
    final date = tester.getRect(find.byKey(const Key('narrow-date')));
    final clear = tester.getRect(
      find.byKey(const Key('uten-date-range-clear')),
    );
    final ordinary = tester.getRect(find.byKey(const Key('narrow-action')));
    expect(date.height, greaterThanOrEqualTo(48));
    expect(clear.height, date.height);
    expect(ordinary.height, date.height);
    for (final bounds in [date, clear, ordinary]) {
      expect(bounds.left, greaterThanOrEqualTo(16));
      expect(bounds.right, lessThanOrEqualTo(304));
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('narrow-date')),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('uten-date-range-clear')),
        matching: find.byIcon(Icons.close_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
