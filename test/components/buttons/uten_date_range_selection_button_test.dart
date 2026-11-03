import 'package:uten_imp/components/layout/uten_app_bar_action_scope.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/buttons/uten_date_range_selection_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/utils/date_range_defaults.dart';

Widget app({
  required FutureOr<void> Function(DateTime?, DateTime?) changed,
  FutureOr<void> Function()? clear,
  bool required = false,
  bool enabled = true,
  DateTime? from,
  DateTime? to,
}) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(
    body: Center(
      child: UtenDateRangeSelectionButton(
        from: from,
        to: to,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        onChanged: changed,
        onClear: clear,
        required: required,
        enabled: enabled,
      ),
    ),
  ),
);

void main() {
  testWidgets('an empty range filter opens with the recent calendar month', (
    tester,
  ) async {
    DateTime? start;
    DateTime? end;
    final expected = recentMonthDateRange();
    await tester.pumpWidget(
      app(
        changed: (from, to) {
          start = from;
          end = to;
        },
      ),
    );
    await tester.tap(find.text('选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(
      start,
      DateTime(expected.start.year, expected.start.month, expected.start.day),
    );
    expect(
      end,
      DateTime(expected.end.year, expected.end.month, expected.end.day),
    );
  });

  testWidgets('rapid taps open one calendar and cancel does not apply', (
    tester,
  ) async {
    var applied = 0;
    await tester.pumpWidget(app(changed: (_, _) => applied++));
    final entry = find.widgetWithText(UtenButton, '选择日期');
    await tester.tap(entry);
    await tester.tap(entry, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(applied, 0);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed request displays one waiting overlay until completion',
    (tester) async {
      var applied = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        app(
          from: DateTime(2026, 9),
          to: DateTime(2026, 9, 30),
          changed: (start, end) {
            applied++;
            expect(start, DateTime(2026, 9));
            expect(end, DateTime(2026, 9, 30));
            return pending.future;
          },
        ),
      );
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(applied, 1);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '选择日期'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clear is a red shared close control inside the card at its right',
    (tester) async {
      var cleared = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        app(
          from: DateTime(2026, 9),
          to: DateTime(2026, 9, 30),
          changed: (_, _) {},
          clear: () {
            cleared++;
            return pending.future;
          },
        ),
      );
      final close = find.byType(UtenCloseButton);
      final card = find
          .ancestor(of: close, matching: find.byType(DecoratedBox))
          .first;
      final closeRect = tester.getRect(close);
      final cardRect = tester.getRect(card);
      expect(closeRect.right, lessThanOrEqualTo(cardRect.right));
      expect(
        closeRect.center.dx,
        greaterThan(tester.getCenter(find.text('选择日期')).dx),
      );
      await tester.tap(close);
      await tester.tap(close, warnIfMissed: false);
      await tester.pump();
      expect(cleared, 1);
      expect(find.byType(UtenDateRangePickerDialog), findsNothing);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
    },
  );

  testWidgets('required business ranges stay empty and have no clear control', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(required: true, changed: (_, _) {}, clear: () {}),
    );
    expect(find.byType(UtenCloseButton), findsNothing);
    await tester.tap(find.byType(UtenButton));
    await tester.pumpAndSettle();
    final confirm = tester.widget<UtenButton>(
      find.widgetWithText(UtenButton, '确定'),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('unmount during an applied request removes its overlay safely', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      app(
        from: DateTime(2026, 9),
        to: DateTime(2026, 9, 30),
        changed: (_, _) => pending.future,
      ),
    );
    await tester.tap(find.text('选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'owner change while the calendar is open cannot publish the old draft',
    (tester) async {
      final owner = ValueNotifier<Object>(Object());
      addTearDown(owner.dispose);
      var applied = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: ValueListenableBuilder<Object>(
            valueListenable: owner,
            builder: (context, identity, _) => UtenActionOwnerScope(
              identity: identity,
              child: Scaffold(
                body: UtenDateRangeSelectionButton(
                  onChanged: (_, _) {
                    applied++;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();
      owner.value = Object();
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(applied, 0);
      expect(find.byType(UtenBusyOverlay), findsNothing);
    },
  );
}
