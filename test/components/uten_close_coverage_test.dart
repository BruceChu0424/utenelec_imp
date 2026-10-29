import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/uten_notify.dart';

void main() {
  for (final width in [375.0, 1280.0]) {
    for (final inLeading in [false, true]) {
      testWidgets(
        'wrapped close stays rightmost at $width leading=$inLeading',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const key = Key('wrapped-close');
          var closes = 0;
          var saves = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                appBar: UtenAppBar(
                  title: 'Details',
                  showPagePermissionAction: false,
                  leading: inLeading
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Align(
                            child: SizedBox(
                              width: 70,
                              child: UtenCloseButton(
                                key: key,
                                onPressed: () => closes++,
                              ),
                            ),
                          ),
                        )
                      : null,
                  actions: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => saves++,
                          child: const Text('Save'),
                        ),
                        if (!inLeading)
                          Padding(
                            padding: const EdgeInsets.only(right: 80),
                            child: UtenWindowControls(
                              closeButtonKey: key,
                              onClose: () => closes++,
                              showExpand: true,
                              onExpand: () {},
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final close = find.byKey(key);
          final appBar = tester.widget<AppBar>(find.byType(AppBar));
          final end = appBar.actionsPadding!.resolve(TextDirection.ltr).right;
          expect(close.hitTestable(), findsOneWidget);
          expect(tester.getRect(close).right, width - end);
          expect(appBar.leading, isA<SizedBox>());
          final more = find.byKey(const Key('uten-app-bar-more-actions'));
          if (width == 375) {
            expect(more.hitTestable(), findsOneWidget);
            await tester.tap(more);
            await tester.pumpAndSettle();
            expect(find.byKey(key), findsOneWidget);
          }
          await tester.tap(find.text('Save').hitTestable());
          await tester.pumpAndSettle();
          expect(saves, 1);
          await tester.tap(close);
          await tester.pumpAndSettle();
          expect(closes, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('untitled close keeps its key and disabled async contract', (
    tester,
  ) async {
    const key = Key('untitled-close');
    final receipt = Completer<void>();
    var calls = 0;
    Widget host(bool enabled) => MaterialApp(
      home: Scaffold(
        body: UtenAlertDialog(
          content: const Text('No title'),
          showCloseButton: true,
          closeEnabled: enabled,
          closeButtonKey: key,
          closeTooltip: 'Close details',
          onClose: () async {
            calls++;
            await receipt.future;
          },
        ),
      ),
    );
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    expect(find.byKey(key).hitTestable(), findsOneWidget);
    final button = find.descendant(
      of: find.byKey(key),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    await tester.tap(find.byKey(key));
    expect(calls, 0);
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    final press = tester.widget<IconButton>(button).onPressed!;
    press();
    press();
    await tester.pump();
    expect(calls, 1);
    receipt.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final confirmAsClose in [false, true]) {
    testWidgets('notification close retains result=$confirmAsClose callback', (
      tester,
    ) async {
      bool? result;
      var confirms = 0;
      var cancels = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await UtenNotify.alert(
                    context,
                    title: 'Download result',
                    message: 'Original file remains unchanged',
                    confirmLabel: confirmAsClose ? 'Got it' : 'Retry',
                    cancelLabel: confirmAsClose ? null : 'Close',
                    confirmAsClose: confirmAsClose,
                    cancelAsClose: !confirmAsClose,
                    onConfirm: () => confirms++,
                    onCancel: () => cancels++,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenCloseButton), findsOneWidget);
      expect(find.text('Close'), findsNothing);
      expect(find.text('Got it'), findsNothing);
      expect(
        find.text('Retry'),
        confirmAsClose ? findsNothing : findsOneWidget,
      );
      await tester.tap(find.byType(UtenCloseButton));
      await tester.pumpAndSettle();
      expect(result, confirmAsClose);
      expect(confirms, confirmAsClose ? 1 : 0);
      expect(cancels, confirmAsClose ? 0 : 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'informational dialog close preserves its receipt and exit wait',
    (tester) async {
      bool? result;
      bool? popped;
      var confirms = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await UtenDialog.show(
                    context,
                    title: 'Opening guide',
                    content: const Text('Read the guide'),
                    confirmLabel: 'Got it',
                    confirmAsClose: true,
                    waitForExit: true,
                    onPopped: (value) => popped = value,
                    onConfirm: () => confirms++,
                  );
                },
                child: const Text('Open guide'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open guide'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenCloseButton).hitTestable(), findsOneWidget);
      expect(find.text('Got it'), findsNothing);
      expect(find.text('取消'), findsNothing);
      await tester.tap(find.byType(UtenCloseButton));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(popped, isTrue);
      expect(confirms, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
