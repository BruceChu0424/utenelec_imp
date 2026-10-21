import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_month_field.dart';
import 'package:uten_imp/components/inputs/uten_reference_picker_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

class _Row extends EditableGridRow {
  final text = TextEditingController(text: '1');
  final focus = FocusNode();
  final choice = ValueNotifier<String?>('short');

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    choice.dispose();
    super.dispose();
  }
}

const _fieldKey = ValueKey('growing-input');
const _long = '采购原料供应商完整名称与规格型号';

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<UtenEditableGridController<_Row>> _mount(
  WidgetTester tester,
  Widget Function(_Row) field, {
  double textScale = 1,
  double width = 120,
  bool stretch = false,
  int rowCount = 1,
}) async {
  final controller = UtenEditableGridController<_Row>(
    initial: List.generate(rowCount, (_) => _Row()),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: ListView(
            children: [
              UtenEditableGrid<_Row>(
                controller: controller,
                showAddRow: false,
                columns: [
                  EditableGridColumn<_Row>(
                    key: 'value',
                    label: '内容',
                    width: width,
                    fillsCellHeight: stretch,
                    // Intentionally no textOf/listenableOf: actual controls
                    // must work without a parallel description of their value.
                    cellBuilder: (_, row) => field(row),
                  ),
                ],
                createBlankRow: _Row.new,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return controller;
}

double _width(WidgetTester tester) =>
    tester.getSize(find.byKey(_fieldKey).first).width;

void main() {
  for (final kind in [
    'text',
    'form',
    'uten',
    'number',
    'reference',
    'multiline',
    'password',
  ]) {
    testWidgets(
      '$kind grows without column text wiring and retains editing state',
      (tester) async {
        final controller = await _mount(tester, (row) {
          return switch (kind) {
            'form' => TextFormField(
              key: _fieldKey,
              controller: row.text,
              focusNode: row.focus,
            ),
            'uten' => UtenInput(
              key: _fieldKey,
              controller: row.text,
              focusNode: row.focus,
              suffixIcon: Icons.edit_outlined,
            ),
            'reference' => UtenReferencePickerField<String>(
              key: _fieldKey,
              controller: row.text,
              label: '货品',
              hint: '搜索货品',
              loadSuggestions: (_) async => [],
              labelOf: (value) => value,
              onSelected: (_) {},
              onInputChanged: (_) {},
              onOpenPicker: (_) async {},
            ),
            _ => TextField(
              key: _fieldKey,
              controller: row.text,
              focusNode: row.focus,
              maxLines: kind == 'multiline' ? 4 : 1,
              obscureText: kind == 'password',
              keyboardType: kind == 'number'
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : null,
              decoration: InputDecoration(
                suffixText: kind == 'number' ? '元' : null,
              ),
            ),
          };
        });
        final row = controller.rows.single;
        final before = _width(tester);
        final editable = find.descendant(
          of: find.byKey(_fieldKey),
          matching: find.byType(EditableText),
        );
        await tester.showKeyboard(editable);
        final state = tester.state<EditableTextState>(editable);
        final text = kind == 'number' ? '12345678901234567890.12' : _long;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
            composing: TextRange(start: 0, end: text.length),
          ),
        );
        await _frames(tester);
        expect(_width(tester), greaterThan(before));
        expect(tester.state<EditableTextState>(editable), same(state));
        expect(state.widget.focusNode.hasFocus, isTrue);
        expect(row.text.value.composing, TextRange(start: 0, end: text.length));
        expect(row.text.selection.baseOffset, text.length);
        final grown = _width(tester);
        row.text.text = '1';
        await _frames(tester);
        expect(_width(tester), grown);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('growth in one row keeps every input in the column aligned', (
    tester,
  ) async {
    final controller = await _mount(
      tester,
      (row) => TextField(key: _fieldKey, controller: row.text),
      rowCount: 2,
    );
    final before = _width(tester);
    controller.rows.last.text.text = _long;
    await _frames(tester);
    final fields = find.byKey(_fieldKey);
    expect(tester.getSize(fields.first).width, greaterThan(before));
    expect(
      tester.getSize(fields.first).width,
      tester.getSize(fields.last).width,
    );
    expect(
      tester.getTopLeft(fields.first).dx,
      tester.getTopLeft(fields.last).dx,
    );
    expect(tester.takeException(), isNull);
  });

  for (final flat in [false, true]) {
    testWidgets(
      'dropdown flat=$flat grows for selected text, not menu choices',
      (tester) async {
        final controller = await _mount(tester, (row) {
          return ValueListenableBuilder<String?>(
            valueListenable: row.choice,
            builder: (_, value, _) => UtenDropdownField(
              key: _fieldKey,
              value: value,
              flat: flat,
              items: const [
                UtenDropdownItem(value: 'short', label: '短'),
                UtenDropdownItem(value: 'long', label: _long),
              ],
              onChanged: (value) => row.choice.value = value,
            ),
          );
        });
        final initial = _width(tester);
        expect(initial, lessThanOrEqualTo(104));
        await tester.tap(find.byKey(_fieldKey));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const ValueKey<(String, Key?, String?)>((
              'uten-dropdown-option',
              _fieldKey,
              'long',
            )),
          ),
        );
        await _frames(tester);
        expect(controller.rows.single.choice.value, 'long');
        expect(_width(tester), greaterThan(initial));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final month in [false, true]) {
    testWidgets(
      'date/month=$month grows with calendar chrome and enlarged text',
      (tester) async {
        await _mount(
          tester,
          (row) => month
              ? UtenMonthField(
                  key: _fieldKey,
                  label: '年月',
                  value: '2026-10',
                  onChanged: (_) {},
                )
              : UtenDateField(
                  key: _fieldKey,
                  label: '日期',
                  value: DateTime(2026, 10, 20),
                  onChanged: (_) {},
                ),
          textScale: 1.5,
          stretch: true,
        );
        expect(_width(tester), greaterThan(104));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compound flex inputs grow together and respect the column cap', (
    tester,
  ) async {
    final controller = await _mount(
      tester,
      (row) => Row(
        key: _fieldKey,
        children: [
          Expanded(flex: 3, child: TextField(controller: row.text)),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: UtenDropdownField(
              value: 'kg',
              items: const [UtenDropdownItem(value: 'kg', label: 'kg')],
              onChanged: (_) {},
            ),
          ),
        ],
      ),
      width: 220,
    );
    final initial = _width(tester);
    controller.rows.single.text.text = '123456789012345';
    await _frames(tester);
    expect(_width(tester), greaterThan(initial));
    final input = find.byType(TextField);
    final renderEditable = tester.renderObject<RenderBox>(
      find.descendant(of: input, matching: find.byType(EditableText)),
    );
    expect(renderEditable.size.width, greaterThan(100));
    controller.rows.single.text.text = _long * 10;
    await _frames(tester);
    expect(_width(tester), closeTo(464, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual resize locks actual inputs, double click restores auto fit',
    (tester) async {
      final controller = await _mount(
        tester,
        (row) => TextField(key: _fieldKey, controller: row.text),
      );
      final header = tester.renderObject<RenderBox>(find.text('内容'));
      final point = header.localToGlobal(
        Offset(-12 + 120 - 2, header.size.height / 2),
      );
      final gesture = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-30, 0));
      await gesture.up();
      await _frames(tester);
      final locked = _width(tester);
      expect(locked, lessThan(104));
      controller.rows.single.text.text = _long;
      await _frames(tester);
      expect(_width(tester), locked);
      final resetPoint = header.localToGlobal(
        Offset(-12 + locked + 16 - 2, header.size.height / 2),
      );
      await tester.tapAt(resetPoint, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(resetPoint, kind: PointerDeviceKind.mouse);
      await _frames(tester);
      expect(_width(tester), greaterThan(locked));
      expect(tester.takeException(), isNull);
    },
  );
}
