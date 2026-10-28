import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_field_suffix_icons.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_picker_icon_button.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

const _message = '单据号由系统生成，保存后可查看。';

Widget _host(Widget child, {bool touch = false}) => MaterialApp(
  theme: buildLightTheme().copyWith(
    platform: touch ? TargetPlatform.android : TargetPlatform.windows,
  ),
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

void _close(WidgetTester tester) {
  Tooltip.dismissAllToolTips();
}

void main() {
  for (final touch in [false, true]) {
    for (final icon in [Icons.autorenew_outlined, Icons.lock_outline]) {
      testWidgets(
        'generated bill number keeps 30px centers and original glyphs $icon touch=$touch',
        (tester) async {
          await tester.pumpWidget(
            _host(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('baseline'),
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: '单据号',
                      suffixIconConstraints: const BoxConstraints(),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const UtenFieldHintIcon(info: _message),
                          SizedBox(
                            width: touch ? 48 : 44,
                            height: touch ? 48 : 44,
                            child: Icon(icon, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                  TextField(
                    key: const ValueKey('with-help'),
                    readOnly: true,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: '单据号',
                        suffixIcon: Icon(icon, size: 18),
                      ),
                      info: _message,
                    ),
                  ),
                ],
              ),
              touch: touch,
            ),
          );
          await tester.pumpAndSettle();
          final field = find.byKey(const ValueKey('with-help'));
          final hint = find.descendant(
            of: field,
            matching: find.byType(UtenFieldHintIcon),
          );
          final business = find.descendant(
            of: field,
            matching: find.byIcon(icon),
          );
          expect(
            tester.getCenter(business).dx - tester.getCenter(hint).dx,
            closeTo(30, .01),
          );
          expect(tester.getSize(business), const Size(18, 18));
          expect(
            tester.getSize(find.byKey(const ValueKey('baseline'))).height,
            tester.getSize(field).height,
          );
          final helpGlyph = find.descendant(
            of: hint,
            matching: find.byIcon(Icons.info_outline),
          );
          expect(tester.getSize(helpGlyph), const Size(18, 18));
          expect(
            tester.getRect(field).contains(tester.getCenter(hint)),
            isTrue,
          );
          expect(
            tester.getRect(field).contains(tester.getCenter(business)),
            isTrue,
          );
          await tester.tap(hint);
          await tester.pumpAndSettle();
          expect(find.text(_message), findsOneWidget);
          _close(tester);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'a custom 40px toolbar retains its original height for plain and picker suffixes',
    (tester) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return Theme(
                data: theme.copyWith(
                  iconButtonTheme: IconButtonThemeData(
                    style: (theme.iconButtonTheme.style ?? const ButtonStyle())
                        .copyWith(
                          minimumSize: const WidgetStatePropertyAll(
                            Size(40, 40),
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.standard,
                        ),
                  ),
                  inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                    constraints: const BoxConstraints(minHeight: 40),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const TextField(
                      key: ValueKey('toolbar-native'),
                      decoration: InputDecoration(
                        hintText: '检索',
                        suffixIcon: Icon(Icons.expand_more, size: 18),
                      ),
                    ),
                    const TextField(
                      key: ValueKey('toolbar-icon'),
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          hintText: '检索',
                          suffixIcon: Icon(Icons.expand_more, size: 18),
                        ),
                      ),
                    ),
                    TextField(
                      key: const ValueKey('toolbar-picker'),
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          hintText: '检索',
                          suffixIcon: UtenFieldSuffixIcons(
                            children: [
                              UtenFieldSuffixIcon(
                                child: UtenPickerIconButton(
                                  tooltip: '选择',
                                  onPressed: () async {},
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final key in ['toolbar-native', 'toolbar-icon', 'toolbar-picker']) {
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          closeTo(40, .01),
          reason: key,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single business icon preserves native field height without help',
    (tester) async {
      for (final touch in [false, true]) {
        await tester.pumpWidget(
          _host(
            const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: ValueKey('native'),
                  decoration: InputDecoration(
                    labelText: '锁定',
                    suffixIcon: Icon(Icons.lock_outline, size: 18),
                  ),
                ),
                TextField(
                  key: ValueKey('compact'),
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '锁定',
                      suffixIcon: Icon(Icons.lock_outline, size: 18),
                    ),
                  ),
                ),
              ],
            ),
            touch: touch,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('compact'))).height,
          tester.getSize(find.byKey(const ValueKey('native'))).height,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'legacy pure-icon Row also compacts while preserving both controls',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _host(
          TextField(
            decoration: UtenInputDecoration(
              InputDecoration(
                labelText: '编号',
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: () => calls++,
                      icon: const Icon(Icons.refresh, size: 18),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.lock_outline, size: 18),
                  ],
                ),
              ),
              info: _message,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byIcon(Icons.refresh)).dx -
            tester.getCenter(find.byType(UtenFieldHintIcon)).dx,
        closeTo(30, .01),
      );
      expect(
        tester.getCenter(find.byIcon(Icons.lock_outline)).dx -
            tester.getCenter(find.byIcon(Icons.refresh)).dx,
        closeTo(32, .01),
      );
      await tester.tap(find.byIcon(Icons.refresh));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hint and password eye retain separate clicks, focus and value', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'original-password');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      _host(
        UtenInput(
          label: '密码',
          info: _message,
          controller: controller,
          focusNode: focus,
          isPassword: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final hint = find.byType(UtenFieldHintIcon);
    final eye = find.byIcon(Icons.visibility_outlined);
    final field = find.byType(TextFormField);
    final originalHeight = tester.getSize(field).height;
    expect(
      tester.getCenter(eye).dx - tester.getCenter(hint).dx,
      closeTo(30, .01),
    );
    await tester.tap(hint);
    await tester.pumpAndSettle();
    expect(find.text(_message), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    _close(tester);
    await tester.pumpAndSettle();
    await tester.tap(eye);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isFalse,
    );
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    expect(controller.text, 'original-password');
    expect(tester.getSize(field).height, originalHeight);
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact business button keeps original identity and disabled isolation',
    (tester) async {
      final actionFocus = FocusNode();
      addTearDown(actionFocus.dispose);
      var calls = 0;
      var enabled = false;
      late StateSetter update;
      final action = IconButton(
        key: const ValueKey('business-action'),
        focusNode: actionFocus,
        onPressed: () => calls++,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        icon: const Icon(Icons.sync, size: 18),
      );
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return TextField(
                enabled: enabled,
                ignorePointers: false,
                decoration: UtenInputDecoration(
                  InputDecoration(labelText: '单据号', suffixIcon: action),
                  info: _message,
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget(find.byKey(const ValueKey('business-action'))),
        same(action),
      );
      final hint = find.byType(UtenFieldHintIcon);
      expect(
        tester.getCenter(find.byIcon(Icons.sync)).dx -
            tester.getCenter(hint).dx,
        closeTo(30, .01),
      );
      await tester.tap(find.byIcon(Icons.sync), warnIfMissed: false);
      actionFocus.requestFocus();
      await tester.pump();
      expect(calls, 0);
      expect(actionFocus.hasFocus, isFalse);
      await tester.tap(hint);
      await tester.pumpAndSettle();
      expect(find.text(_message), findsOneWidget);
      _close(tester);
      update(() => enabled = true);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.sync));
      expect(calls, 1);
      expect(
        tester.widget(find.byKey(const ValueKey('business-action'))),
        same(action),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pure icon rows and custom picker slots keep independent actions',
    (tester) async {
      var clear = 0, picked = 0;
      await tester.pumpWidget(
        _host(
          TextField(
            decoration: UtenInputDecoration(
              InputDecoration(
                labelText: '来源',
                suffixIcon: UtenFieldSuffixIcons(
                  children: [
                    IconButton(
                      onPressed: () => clear++,
                      icon: const Icon(Icons.clear, size: 18),
                    ),
                    UtenFieldSuffixIcon(
                      child: UtenPickerIconButton(
                        tooltip: '选择来源',
                        onPressed: () async {
                          picked++;
                        },
                      ),
                    ),
                  ],
                ),
              ),
              info: _message,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hint = find.byType(UtenFieldHintIcon);
      final clearIcon = find.byIcon(Icons.clear);
      final picker = find.byIcon(Icons.more_horiz_rounded);
      expect(
        tester.getCenter(clearIcon).dx - tester.getCenter(hint).dx,
        closeTo(30, .01),
      );
      expect(
        tester.getCenter(picker).dx - tester.getCenter(clearIcon).dx,
        closeTo(32, .01),
      );
      await tester.tap(clearIcon);
      await tester.pump();
      expect(clear, 1);
      expect(picked, 0);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(picked, 1);
      expect(clear, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('business text suffix retains its natural width', (tester) async {
    const business = 'kg / 原始单位 / 不可截断的装饰文字';
    await tester.pumpWidget(
      _host(
        const TextField(
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: '重量',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [Text(business)],
              ),
            ),
            info: _message,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(business), findsOneWidget);
    expect(tester.getSize(find.text(business)).width, greaterThan(100));
    expect(tester.widget<Text>(find.text(business)).overflow, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'table cell hint stays zero width and business 24px slot is unchanged',
    (tester) async {
      final controller = TextEditingController(text: '12');
      addTearDown(controller.dispose);
      var hasInfo = false;
      late StateSetter update;
      var clicks = 0;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return UtenTableCellInputTheme(
                child: UtenTableCellHints(
                  child: TextField(
                    controller: controller,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        isDense: true,
                        suffixIconConstraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 24,
                        ),
                        suffixIcon: IconButton(
                          key: const ValueKey('cell-action'),
                          onPressed: () => clicks++,
                          constraints: const BoxConstraints.tightFor(
                            width: 24,
                            height: 24,
                          ),
                          padding: const EdgeInsets.all(4),
                          icon: const Icon(Icons.scale_outlined, size: 16),
                        ),
                      ),
                      info: hasInfo ? _message : null,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editable = find.byType(EditableText);
      final widthBefore = tester.getSize(editable).width;
      final heightBefore = tester.getSize(find.byType(TextField)).height;
      final button = find.byKey(const ValueKey('cell-action'));
      expect(tester.getSize(button), const Size(24, 24));
      update(() => hasInfo = true);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(UtenFieldHintIcon)), Size.zero);
      expect(find.byIcon(Icons.info_outline), findsNothing);
      expect(tester.getSize(editable).width, widthBefore);
      expect(tester.getSize(find.byType(TextField)).height, heightBefore);
      expect(tester.getSize(button), const Size(24, 24));
      await tester.tap(button);
      expect(clicks, 1);
      expect(controller.text, '12');
      expect(tester.takeException(), isNull);
    },
  );
}
