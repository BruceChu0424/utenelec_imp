import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/employee/widgets/employee_contact_edit_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';

class _Row extends EditableGridRow {
  _Row(this.name);
  final String name;
  @override
  void dispose() {}
}

UtenEditableGrid<_Row> _grid(
  UtenEditableGridController<_Row> controller, {
  required bool add,
}) => UtenEditableGrid<_Row>(
  controller: controller,
  columns: [
    EditableGridColumn<_Row>(
      key: 'name',
      label: '名称',
      width: 160,
      cellBuilder: (_, row) => Text(row.name),
    ),
  ],
  createBlankRow: () => _Row('新行'),
  cloneRow: (row) => _Row(row.name),
  showAddRow: add,
  selectable: !add,
);

Widget _app(Widget home, ValueNotifier<double> keyboard) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => ValueListenableBuilder<double>(
    valueListenable: keyboard,
    builder: (_, bottom, _) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(viewInsets: EdgeInsets.only(bottom: bottom)),
      child: child!,
    ),
  ),
  home: home,
);

void _alive(TextEditingController controller) {
  void listener() {}
  expect(() => controller.addListener(listener), returnsNormally);
  controller.removeListener(listener);
}

void _released(TextEditingController controller) {
  expect(() => controller.addListener(() {}), throwsFlutterError);
}

void main() {
  for (final confirm in [false, true]) {
    testWidgets(
      'employee phone ${confirm ? 'confirm' : 'cancel'} retains the controller until exit',
      (tester) async {
        final keyboard = ValueNotifier(220.0);
        addTearDown(keyboard.dispose);
        String? returned;
        var callbacks = 0;
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () async {
                    returned = await showEmployeeChangePhoneDialog(
                      context,
                      '13900139000',
                    );
                    callbacks++;
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
            keyboard,
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog).last;
        final field = find.descendant(
          of: dialog,
          matching: find.byType(TextField),
        );
        final controller = tester.widget<TextField>(field).controller!;
        await tester.enterText(field, '13800138000');
        final route = ModalRoute.of(tester.element(dialog))!;
        var exited = false;
        route.completed.then((_) => exited = true);
        await tester.tap(
          find.descendant(
            of: dialog,
            matching: find.text(confirm ? '确定更换' : '取消'),
          ),
        );
        await tester.pump();
        expect(exited, isFalse);
        expect(callbacks, 0);
        _alive(controller);
        // A late focus/IME/layout update must never see a disposed controller.
        controller.text = '13999999999';
        keyboard.value = 100;
        await tester.pump();
        _alive(controller);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(exited, isTrue);
        _released(controller);
        expect(callbacks, 1);
        expect(returned, confirm ? '13800138000' : null);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final add in [false, true]) {
    for (final confirm in [false, true]) {
      testWidgets(
        '${add ? 'add' : 'paste'} rows ${confirm ? 'confirm' : 'cancel'} owns the count controller through exit',
        (tester) async {
          final keyboard = ValueNotifier(0.0);
          addTearDown(keyboard.dispose);
          final rows = UtenEditableGridController<_Row>(initial: [_Row('原行')]);
          if (!add) {
            rows.selectAll();
            rows.copySelected((row) => _Row(row.name));
            rows.clearSelection();
          }
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: ListView(children: [_grid(rows, add: add)]),
              ),
              keyboard,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(add ? '添加多行' : '粘贴多行'));
          await tester.pumpAndSettle();
          final dialog = find.byType(AlertDialog).last;
          final field = find.descendant(
            of: dialog,
            matching: find.byType(TextField),
          );
          final controller = tester.widget<TextField>(field).controller!;
          await tester.enterText(field, '3');
          final route = ModalRoute.of(tester.element(dialog))!;
          var exited = false;
          route.completed.then((_) => exited = true);
          await tester.tap(
            find.descendant(
              of: dialog,
              matching: find.text(confirm ? (add ? '添加' : '确定') : '取消'),
            ),
          );
          await tester.pump();
          expect(exited, isFalse);
          _alive(controller);
          expect(rows.rows.length, 1);
          controller.text = '50';
          keyboard.value = 100;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(exited, isTrue);
          _released(controller);
          expect(
            rows.rows.length,
            confirm ? 4 : 1,
            reason: 'The confirmed quantity is immutable and applies once.',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          rows.dispose();
        },
      );
    }
  }

  testWidgets(
    'snapshot hook failure still waits for route exit before owner cleanup',
    (tester) async {
      final keyboard = ValueNotifier(0.0);
      addTearDown(keyboard.dispose);
      final controller = TextEditingController();
      Object? captured;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  try {
                    await UtenDialog.showAndWaitForExit<bool>(
                      context,
                      onPopped: (_) => throw StateError('snapshot failure'),
                      builder: (dialogContext) => UtenAlertDialog(
                        content: TextField(controller: controller),
                        actions: [
                          FilledButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('确认'),
                          ),
                        ],
                      ),
                    );
                  } catch (error) {
                    captured = error;
                  } finally {
                    controller.dispose();
                  }
                },
                child: const Text('打开'),
              ),
            ),
          ),
          keyboard,
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pump();
      _alive(controller);
      expect(captured, isNull);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(captured, isA<StateError>());
      _released(controller);
      expect(tester.takeException(), isNull);
    },
  );
}
