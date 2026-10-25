import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

const _name = '同名产品';
const _firstLabel = 'HP001 · 同名产品完整名称及第一道装配与检验工序';
const _secondLabel = 'HP002 · 同名产品完整名称及第二道装配与检验工序';
const _blockedLabel = 'HP003 · 此工单当前不允许接收产出，请先核对任务状态';
const _items = [
  UtenDropdownItem(value: 'first-demand', label: _firstLabel),
  UtenDropdownItem(value: 'second-demand', label: _secondLabel),
  UtenDropdownItem(
    value: 'blocked-demand',
    label: _blockedLabel,
    enabled: false,
    error: true,
  ),
];

void main() {
  testWidgets('stable menu key selects its own value among duplicate labels', (
    tester,
  ) async {
    const Key fieldKey = ValueKey('duplicate-label-field');
    String? selected = 'first-demand';
    await _pumpField(
      tester,
      fieldKey: fieldKey,
      value: () => selected,
      items: const [
        UtenDropdownItem(value: 'first-demand', label: _name),
        UtenDropdownItem(value: 'second-demand', label: _name),
        UtenDropdownItem(label: '默认处理方式'),
      ],
      allowClear: true,
      onChanged: (value) => selected = value,
    );
    await tester.tap(find.byKey(fieldKey));
    await tester.pumpAndSettle();
    expect(find.text(_name), findsNWidgets(3));
    await tester.tap(
      find.byKey(
        const ValueKey<(String, Key?, String?)>((
          'uten-dropdown-option',
          fieldKey,
          'second-demand',
        )),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, 'second-demand');
    await tester.tap(find.byKey(fieldKey));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<(String, Key?, String?)>((
          'uten-dropdown-option',
          fieldKey,
          null,
        )),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const ValueKey<(String, Key?)>((
          'uten-dropdown-clear-option',
          fieldKey,
        )),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text(_name), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final flat in [false, true]) {
    testWidgets('selected label preserves distinct choice identities ($flat)', (
      tester,
    ) async {
      String? selected = 'first-demand';
      await _pumpField(
        tester,
        flat: flat,
        value: () => selected,
        selectedLabel: _name,
        onChanged: (value) => selected = value,
      );
      expect(find.text(_name), findsOneWidget);
      expect(find.text(_firstLabel), findsNothing);
      final collapsed = tester.widget<Text>(find.text(_name));
      expect(collapsed.maxLines, 1);
      expect(collapsed.overflow, TextOverflow.ellipsis);

      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      expect(find.text(_firstLabel), findsOneWidget);
      expect(find.text(_secondLabel), findsOneWidget);
      await tester.tap(find.text(_secondLabel));
      await tester.pumpAndSettle();
      expect(selected, 'second-demand');
      expect(
        tester.widget<UtenDropdownField>(find.byType(UtenDropdownField)).value,
        'second-demand',
      );
      expect(find.text(_name), findsOneWidget);
      expect(find.text(_secondLabel), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'ordinary menu option wraps fully and preserves its exact hover label',
    (tester) async {
      await _pumpField(tester, selectedLabel: _name);
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      final label = tester.widget<Text>(find.text(_firstLabel));
      expect(label.maxLines, isNull);
      expect(label.overflow, TextOverflow.clip);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == _firstLabel,
        ),
        findsOneWidget,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text(_firstLabel)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.text(_firstLabel, findRichText: true),
        findsAtLeastNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selected label does not change menu search or keyboard values', (
    tester,
  ) async {
    String? selected = 'first-demand';
    await _pumpField(
      tester,
      value: () => selected,
      selectedLabel: _name,
      searchable: true,
      onChanged: (value) => selected = value,
    );
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'HP002');
    await tester.pump();
    expect(find.text(_firstLabel), findsNothing);
    expect(find.text(_secondLabel), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(selected, 'second-demand');
    expect(find.text(_name), findsOneWidget);
  });

  testWidgets('disabled and error states retain labels and selection guards', (
    tester,
  ) async {
    final changes = <String?>[];
    await _pumpField(
      tester,
      selectedLabel: _name,
      errorMessage: '请重新核对来源工单',
      onChanged: changes.add,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    final blockedText = tester.widget<Text>(find.text(_blockedLabel));
    expect(blockedText.style?.color, buildLightTheme().colorScheme.error);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == _blockedLabel,
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(_blockedLabel));
    await tester.pump();
    expect(changes, isEmpty);
    expect(find.text(_secondLabel), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpField(tester, selectedLabel: _name, enabled: false);
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    expect(find.text(_name), findsOneWidget);
    expect(find.text(_firstLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'override never supplies a missing value or exposes hidden choices',
    (tester) async {
      await _pumpField(tester, value: () => null, selectedLabel: _name);
      expect(find.text('工单'), findsWidgets);
      expect(find.text(_name), findsNothing);

      await _pumpField(
        tester,
        selectedLabel: _name,
        items: const [
          UtenDropdownItem(
            value: 'first-demand',
            label: _firstLabel,
            visible: false,
            enabled: false,
          ),
          UtenDropdownItem(value: 'second-demand', label: _secondLabel),
        ],
      );
      expect(find.text(_name), findsOneWidget);
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      expect(find.text(_firstLabel), findsNothing);
      expect(find.text(_secondLabel), findsOneWidget);
    },
  );

  testWidgets(
    'omitting selected label keeps the original selected item label',
    (tester) async {
      await _pumpField(tester);
      expect(find.text(_firstLabel), findsOneWidget);
      expect(find.text(_name), findsNothing);
    },
  );

  testWidgets('menu follows both nested viewports and window resizing', (
    tester,
  ) async {
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 220,
              height: 300,
              child: SingleChildScrollView(
                controller: outer,
                child: Column(
                  children: [
                    const SizedBox(height: 60),
                    SizedBox(
                      height: 240,
                      child: SingleChildScrollView(
                        controller: inner,
                        child: Column(
                          children: [
                            const SizedBox(height: 80),
                            UtenDropdownField(
                              value: 'first-demand',
                              items: _items,
                              allowClear: false,
                              searchable: false,
                              onChanged: (_) {},
                            ),
                            const SizedBox(height: 500),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 500),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final field = find.byType(UtenDropdownField);
    await tester.tap(field);
    await tester.pumpAndSettle();
    final menuItem = find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == _firstLabel,
    );
    final before = tester.getRect(menuItem);
    expect(before.width, 220);
    outer.jumpTo(20);
    await tester.pumpAndSettle();
    expect(tester.getRect(menuItem).top, moreOrLessEquals(before.top - 20));
    inner.jumpTo(40);
    await tester.pumpAndSettle();
    expect(tester.getRect(menuItem).top, moreOrLessEquals(before.top - 60));
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpAndSettle();
    final resizedField = tester.getRect(field);
    final resizedMenu = tester.getRect(menuItem);
    expect(resizedMenu.left, moreOrLessEquals(resizedField.left));
    final resizedSurface = tester.getRect(
      find.ancestor(of: menuItem, matching: find.byType(Material)).first,
    );
    expect(resizedSurface.top, moreOrLessEquals(resizedField.bottom + 2));
    expect(resizedMenu.width, moreOrLessEquals(resizedField.width));
    await tester.tapAt(const Offset(10, 500));
    await tester.pumpAndSettle();
    expect(menuItem, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu opens above a bottom field and respects visual scaling', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Transform.scale(
              scale: 0.8,
              child: SizedBox(
                width: 220,
                child: UtenDropdownField(
                  value: 'first-demand',
                  items: _items,
                  allowClear: false,
                  searchable: false,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final field = tester.getRect(find.byType(UtenDropdownField));
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    final bottomItem = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == _blockedLabel,
      ),
    );
    expect(bottomItem.width, moreOrLessEquals(field.width));
    expect(bottomItem.bottom, moreOrLessEquals(field.top - 2));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpField(
  WidgetTester tester, {
  Key? fieldKey,
  String? Function()? value,
  String? selectedLabel,
  bool flat = false,
  bool enabled = true,
  bool searchable = false,
  bool allowClear = false,
  String? errorMessage,
  List<UtenDropdownItem> items = _items,
  ValueChanged<String?>? onChanged,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 220,
          child: StatefulBuilder(
            builder: (context, setState) => UtenDropdownField(
              key: fieldKey,
              value: value?.call() ?? (value == null ? 'first-demand' : null),
              selectedLabel: selectedLabel,
              items: items,
              onChanged: (value) => setState(() => onChanged?.call(value)),
              allowClear: allowClear,
              searchable: searchable,
              flat: flat,
              enabled: enabled,
              errorMessage: errorMessage,
              hintText: '选择工单',
            ),
          ),
        ),
      ),
    ),
  ),
);
