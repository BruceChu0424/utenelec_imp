import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';

typedef _Row = ({String id, String name});
final _name = MasterInlineField<_Row>(
  key: 'name',
  read: (row) => row.name,
  required: true,
);

void main() {
  testWidgets(
    'save ends the focused input before freezing, preserves composed text and sends only once',
    (tester) async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      final response = Completer<void>();
      final writes = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: MasterInlineRecordEditor<_Row>(
                    controller: controller,
                    row: (id: 'one', name: 'Before'),
                    idOf: (row) => row.id,
                    fields: {'name': _name},
                    columns: [
                      MasterColumnDef(
                        key: 'name',
                        label: '名称',
                        width: 220,
                        value: (row) => row.name,
                      ),
                    ],
                  ),
                ),
                MasterInlineEditActions<_Row>(
                  controller: controller,
                  canEdit: true,
                  embedded: true,
                  onSave: (_, patch) {
                    writes.add(patch);
                    return response.future;
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inline-activate-one-name')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      const input = TextEditingValue(
        text: '原文拼音',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      );
      tester.testTextInput.updateEditingValue(input);
      await tester.pumpAndSettle();
      expect(field.focusNode!.hasFocus, isTrue);
      final focusWhenBusy = <bool>[];
      void recordBusy() {
        if (controller.busy) focusWhenBusy.add(field.focusNode!.hasFocus);
      }

      controller.addListener(recordBusy);
      addTearDown(() => controller.removeListener(recordBusy));
      final action = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '保存 1 行修改'),
      );
      action.onPressed!();
      action.onPressed!();
      for (var frame = 0; frame < 12 && writes.isEmpty; frame++) {
        await tester.pump();
      }
      expect(focusWhenBusy, isNotEmpty);
      expect(focusWhenBusy, everyElement(isFalse));
      expect(writes, [
        {'name': input.text},
      ]);
      expect(field.controller!.text, input.text);
      expect(field.controller!.selection, input.selection);
      response.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a save waiting for input exit cannot save a replacement edit session',
    (tester) async {
      final controller = MasterInlineEditController<_Row>()..begin();
      addTearDown(controller.dispose);
      controller.setValue('one', _name, 'Old draft', originalValue: 'Before');
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MasterInlineEditActions<_Row>(
              controller: controller,
              canEdit: true,
              onSave: (_, _) async {
                writes++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '保存 1 行修改'))
          .onPressed!();
      controller.cancel();
      controller.begin();
      controller.setValue('one', _name, 'New draft', originalValue: 'Before');
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(controller.patchFor('one'), {'name': 'New draft'});
      expect(tester.takeException(), isNull);
    },
  );
}
