import 'package:uten_imp/components/layout/uten_app_bar_action_scope.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_date_range_selection_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/utils/date_range_defaults.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/utils/date_range_display.dart';

Widget app({
  required FutureOr<void> Function(DateTime?, DateTime?) changed,
  FutureOr<void> Function()? clear,
  bool required = false,
  bool enabled = true,
  DateTime? from,
  DateTime? to,
  String? label,
  String? info,
  String? errorMessage,
}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.windows),
  locale: const Locale('zh'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(
    body: Center(
      child: UtenDateRangeSelectionButton(
        buttonKey: const Key('test-range-entry'),
        from: from,
        to: to,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        onChanged: changed,
        onClear: clear,
        required: required,
        enabled: enabled,
        label: label,
        info: info,
        errorMessage: errorMessage,
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
      await tester.tap(find.byKey(const Key('test-range-entry')));
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
            .widget<UtenButton>(find.byKey(const Key('test-range-entry')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clear is an icon free text action inside the card with the same height',
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
      final close = find.byKey(const Key('uten-date-range-clear'));
      final card = find
          .ancestor(of: close, matching: find.byType(DecoratedBox))
          .first;
      final closeRect = tester.getRect(close);
      final cardRect = tester.getRect(card);
      expect(closeRect.right, lessThanOrEqualTo(cardRect.right));
      expect(
        closeRect.center.dx,
        greaterThan(
          tester.getCenter(find.byKey(const Key('test-range-entry'))).dx,
        ),
      );
      expect(
        find.descendant(of: card, matching: find.byType(Icon)),
        findsNothing,
      );
      expect(
        closeRect.height,
        tester.getSize(find.byKey(const Key('test-range-entry'))).height,
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
    expect(find.byKey(const Key('uten-date-range-clear')), findsNothing);
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
    await tester.tap(find.byKey(const Key('test-range-entry')));
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

  testWidgets(
    'selected range is short and the whole button immediately reveals dates',
    (tester) async {
      final today = ChinaDateTime.today();
      final start = today.subtract(const Duration(days: 89));
      final message = dateRangeTooltip(from: start, to: today);
      await tester.pumpWidget(app(from: start, to: today, changed: (_, _) {}));
      final entry = find.byKey(const Key('test-range-entry'));
      expect(find.text('近90天'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getTopLeft(entry) + const Offset(2, 2));
      await tester.pump();
      expect(find.text(message), findsOneWidget);
      expect(find.byType(UtenDateRangePickerDialog), findsNothing);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'keyboard focus reveals dates, labels and validation without hint icons',
    (tester) async {
      await tester.pumpWidget(
        app(
          from: DateTime(2026, 10),
          to: DateTime(2026, 12),
          label: '计划日期',
          info: '保留原计划日期',
          errorMessage: '日期超出有效期',
          changed: (_, _) {},
        ),
      );
      expect(find.text('计划日期：共62天'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('2026.10.01-2026.12.01\n\n日期超出有效期\n\n保留原计划日期'),
        findsOneWidget,
      );
      expect(find.byType(UtenDateRangePickerDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'date and ordinary actions share desktop height before and after selection',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dates = ValueNotifier<DateTimeRange?>(null);
      addTearDown(dates.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Center(
              child: ValueListenableBuilder<DateTimeRange?>(
                valueListenable: dates,
                builder: (_, range, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UtenDateRangeSelectionButton(
                      from: range?.start,
                      to: range?.end,
                      onChanged: (_, _) {},
                      onClear: () => dates.value = null,
                    ),
                    UtenButton(
                      key: const Key('ordinary-action'),
                      onPressed: () {},
                      child: const Text('下载表格'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final date = find.byType(UtenDateRangeSelectionButton);
      final action = find.byKey(const Key('ordinary-action'));
      expect(tester.getSize(date).height, tester.getSize(action).height);
      dates.value = DateTimeRange(
        start: DateTime(2026, 10),
        end: DateTime(2026, 12),
      );
      await tester.pump();
      expect(tester.getSize(date).height, tester.getSize(action).height);
      expect(tester.getSize(date).height, 40);
      expect(find.text('共62天'), findsOneWidget);
      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
      expect(find.text('选择日期'), findsOneWidget);
    },
  );
}
