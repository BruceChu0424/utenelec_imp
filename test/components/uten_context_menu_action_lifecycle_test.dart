import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';

Widget _app(Widget child) => MaterialApp(
  builder: (_, child) => UtenContextMenuPolicy(child: child!),
  home: Scaffold(body: SizedBox(width: 500, height: 300, child: child)),
);

Widget _host({
  required UtenMenuItem item,
  required Future<void> Function() cleanup,
}) => _app(
  UtenContextMenuRegion(
    entriesBuilder: () => [item],
    onActionCompleted: cleanup,
    child: const Center(child: Text('Source row')),
  ),
);

Future<void> _open(WidgetTester tester) async {
  final mouse = await tester.startGesture(
    tester.getCenter(find.text('Source row')),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await mouse.up();
  await tester.pumpAndSettle();
}

void main() {
  const label = 'context region';

  testWidgets('$label cleans exactly once after asynchronous action', (
    tester,
  ) async {
    final actionGate = Completer<void>();
    final events = <String>[];
    var selected = <String>{'source'};
    await tester.pumpWidget(
      _host(
        item: UtenMenuItem(
          label: 'Normal action',
          onTap: () async {
            events.add('started');
            await actionGate.future;
            selected = {'updated'};
            events.add('finished');
          },
        ),
        cleanup: () async {
          events.add('cleanup');
          selected = {};
        },
      ),
    );
    await _open(tester);
    await tester.tap(find.text('Normal action'));
    await tester.pump();
    expect(find.text('Normal action'), findsNothing);
    expect(events, ['started']);
    expect(selected, {'source'});
    actionGate.complete();
    await tester.pumpAndSettle();
    expect(events, ['started', 'finished', 'cleanup']);
    expect(selected, isEmpty);
  });

  testWidgets('$label keeps an action-created selection without a rebuild', (
    tester,
  ) async {
    final actionGate = Completer<void>();
    var selected = <String>{'source'};
    var cleanups = 0;
    await tester.pumpWidget(
      _host(
        item: UtenMenuItem(
          label: 'Paste copies',
          preserveSelectionAfterAction: true,
          onTap: () async {
            await actionGate.future;
            // No pump or rebuilt selectedIds widget between this authoritative
            // selection change and menu completion, matching async paste.
            selected = {'copy-1', 'copy-2'};
          },
        ),
        cleanup: () async {
          cleanups++;
          selected = {};
        },
      ),
    );
    await _open(tester);
    await tester.tap(find.text('Paste copies'));
    await tester.pump();
    actionGate.complete();
    await tester.pumpAndSettle();
    expect(selected, {'copy-1', 'copy-2'});
    expect(cleanups, 0);
  });

  testWidgets('$label dismissal does not run action or selection cleanup', (
    tester,
  ) async {
    var actions = 0;
    var cleanups = 0;
    await tester.pumpWidget(
      _host(
        item: UtenMenuItem(label: 'Action', onTap: () => actions++),
        cleanup: () async {
          cleanups++;
        },
      ),
    );
    await _open(tester);
    await tester.tapAt(const Offset(10, 550));
    await tester.pumpAndSettle();
    expect(find.text('Action'), findsNothing);
    expect(actions, 0);
    expect(cleanups, 0);
  });

  testWidgets('show future includes the selected-item completion hook', (
    tester,
  ) async {
    final cleanupGate = Completer<void>();
    final item = UtenMenuItem(label: 'Action', onTap: () {});
    UtenMenuItem? completedItem;
    UtenContextMenuCloseReason? closeReason;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              closeReason = await showUtenContextMenu(
                context,
                globalPosition: const Offset(50, 50),
                entries: [item],
                onActionCompleted: (selected) async {
                  completedItem = selected;
                  await cleanupGate.future;
                },
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'));
    await tester.pump();
    expect(completedItem, same(item));
    expect(closeReason, isNull);
    cleanupGate.complete();
    await tester.pumpAndSettle();
    expect(closeReason, UtenContextMenuCloseReason.actionCompleted);
  });
}
