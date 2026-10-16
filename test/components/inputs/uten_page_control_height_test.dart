import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_filter_picker_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';

final _outline = find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint &&
      widget.foregroundPainter?.runtimeType.toString() == '_InputBorderPainter',
);

void main() {
  for (final dark in [false, true]) {
    for (final touch in [false, true]) {
      testWidgets(
        'normal fields share their own outline dark=$dark touch=$touch',
        (tester) async {
          tester.view.physicalSize = Size(touch ? 390 : 1280, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          Widget field(String key, Widget child) =>
              SizedBox(key: ValueKey(key), width: 280, child: child);
          await tester.pumpWidget(
            MaterialApp(
              theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
                platform: touch
                    ? TargetPlatform.android
                    : TargetPlatform.windows,
              ),
              home: Scaffold(
                body: UtenControlTheme(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      field('search', const UtenSearchBar()),
                      field('plain', const TextField()),
                      field('input', const UtenInput(label: '货品名称')),
                      field(
                        'emptyLabel',
                        const TextField(
                          decoration: InputDecoration(labelText: '货品名称'),
                        ),
                      ),
                      field('password', const UtenInput(isPassword: true)),
                      field('hint', const UtenInput(info: '字段说明')),
                      field(
                        'dropdown',
                        UtenDropdownField(
                          label: '主仓库',
                          value: '1',
                          items: const [
                            UtenDropdownItem(value: '1', label: '主仓库'),
                          ],
                          onChanged: (_) {},
                        ),
                      ),
                      field(
                        'date',
                        UtenDateField(
                          label: '单据日期',
                          value: DateTime(2026, 10, 13),
                          onChanged: (_) {},
                        ),
                      ),
                      field(
                        'filter',
                        UtenFilterPickerField(
                          label: '仓库',
                          value: '主仓库',
                          onTap: () {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          double outlineHeight(String key) => tester
              .getSize(
                find.descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: _outline,
                ),
              )
              .height;
          final search = outlineHeight('search');
          expect(search, touch ? 48 : 36);
          for (final key in [
            'plain',
            'input',
            'emptyLabel',
            'password',
            'hint',
            'dropdown',
            'date',
          ]) {
            expect(
              outlineHeight(key),
              closeTo(touch ? 48 : 44, 0.5),
              reason: key,
            );
          }
          expect(
            tester.getSize(find.byKey(const ValueKey('filter'))).height,
            closeTo(search, 0.5),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
