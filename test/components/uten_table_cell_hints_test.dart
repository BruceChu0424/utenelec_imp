import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row extends EditableGridRow {}

void main() {
  testWidgets(
    'nested table headers keep help and overflowing cell text uses no icon',
    (tester) async {
      const message = '数量发生变化，请重新核对该行最新的仓库可用数量';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenTableCellHints(
              child: SizedBox(
                width: 160,
                child: Column(
                  children: [
                    UtenColumnHeaderInfo(label: Text('数量'), message: '表头说明'),
                    UtenOverflowMessage(message: message),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
      expect(find.byTooltip(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'editable grid keeps header help and row errors without cell icons',
    (tester) async {
      final controller = UtenEditableGridController<_Row>(initial: [_Row()]);
      final form = GlobalKey<FormState>();
      final field = GlobalKey<FormFieldState<String>>();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: form,
              child: ListView(
                children: [
                  UtenEditableGrid<_Row>(
                    controller: controller,
                    createBlankRow: _Row.new,
                    columns: [
                      EditableGridColumn<_Row>(
                        key: 'qty',
                        label: '数量',
                        headerInfo: '填写本次数量',
                        width: 200,
                        cellBuilder: (_, _) => TextFormField(
                          key: field,
                          initialValue: '0',
                          validator: (value) => value == '2' ? null : '数量必须大于零',
                          errorBuilder: utenTextFieldErrorBuilder,
                          decoration: const UtenInputDecoration(
                            InputDecoration(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editable = find.byType(EditableText);
      final normalWidth = tester.getSize(editable).width;
      expect(form.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(tester.getSize(editable).width, greaterThanOrEqualTo(normalWidth));
      expect(find.byTooltip('数量必须大于零'), findsOneWidget);
      final cellHint = find.descendant(
        of: find.byType(UtenTableCellHints),
        matching: find.byType(UtenFieldHintIcon),
      );
      expect(tester.getSize(cellHint), Size.zero);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(editable));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('数量必须大于零'), findsOneWidget);
      await mouse.removePointer();
      await tester.enterText(find.byType(TextFormField), '2');
      expect(form.currentState!.validate(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byTooltip('数量必须大于零'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'master table suppresses hints while dropdown actions remain usable',
    (tester) async {
      String? selected = 'usd';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MasterDataTableView<String>(
                columns: [
                  MasterColumnDef<String>(
                    key: 'title',
                    label: '单据',
                    width: 100,
                    value: (item) => item,
                  ),
                  MasterColumnDef<String>(
                    key: 'currency',
                    label: '币种',
                    width: 250,
                    value: (_) => selected,
                    cellBuilder: (_, _) => UtenDropdownField(
                      value: selected,
                      autofilled: true,
                      items: const [
                        UtenDropdownItem(value: 'usd', label: 'USD'),
                        UtenDropdownItem(value: 'cny', label: 'CNY'),
                      ],
                      onChanged: (value) => setState(() => selected = value),
                    ),
                  ),
                ],
                items: const ['row'],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                showFullscreenToggle: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.byIcon(Icons.arrow_drop_down_rounded), findsOneWidget);
      expect(find.byTooltip('已按上次记录预填，请核对'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CNY'));
      await tester.pumpAndSettle();
      expect(selected, 'cny');
      expect(tester.takeException(), isNull);
    },
  );
}
