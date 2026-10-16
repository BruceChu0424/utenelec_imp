import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_month_field.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    if (const bool.fromEnvironment('UI_CAPTURE')) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final dark in [false, true]) {
    for (final touch in [false, true]) {
      for (final controlTheme in [false, true]) {
        // Touch geometry is supplied by the media-aware application host.
        if (touch && !controlTheme) continue;
        for (final scale in [1.0, 1.5, 2.0]) {
          testWidgets(
            'real form outlines scale=$scale dark=$dark touch=$touch host=$controlTheme',
            (tester) async {
              tester.view.physicalSize = Size(touch ? 390 : 1200, 1000);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              Widget field(String key, Widget child) =>
                  SizedBox(key: ValueKey(key), width: 360, child: child);
              final capture = GlobalKey();
              Widget host(Widget child) => RepaintBoundary(
                key: capture,
                child: controlTheme ? UtenControlTheme(child: child) : child,
              );
              await tester.pumpWidget(
                MaterialApp(
                  theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
                    platform: touch
                        ? TargetPlatform.android
                        : TargetPlatform.windows,
                    // ThemeData.platform does not update adaptivePlatformDensity. Set the
                    // real desktop density explicitly to reproduce the 36px/44px bug.
                    visualDensity: touch
                        ? VisualDensity.standard
                        : VisualDensity.compact,
                  ),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: host(
                      Column(
                        children: [
                          field(
                            'plain',
                            const UtenInput(label: '货品名称', required: true),
                          ),
                          field(
                            'info',
                            const UtenInput(label: '英文名称', info: '货品英文名称'),
                          ),
                          field(
                            'dropdown',
                            UtenDropdownField(
                              label: '来源',
                              value: null,
                              items: const [],
                              onChanged: (_) {},
                            ),
                          ),
                          field(
                            'disabled',
                            const UtenInput(label: '编号', enabled: false),
                          ),
                          field(
                            'native',
                            const TextField(
                              decoration: InputDecoration(labelText: '规格'),
                            ),
                          ),
                          field(
                            'selected',
                            UtenDropdownField(
                              label: '状态',
                              value: 'active',
                              items: const [
                                UtenDropdownItem(value: 'active', label: '使用'),
                              ],
                              onChanged: (_) {},
                            ),
                          ),
                          field(
                            'error',
                            const UtenInput(
                              label: '基本单位',
                              errorMessage: '请选择基本单位',
                            ),
                          ),
                          field(
                            'date',
                            UtenDateField(
                              label: '制造日期',
                              value: DateTime(2026, 10, 16),
                              onChanged: (_) {},
                            ),
                          ),
                          field(
                            'month',
                            UtenMonthField(
                              label: '制造年月',
                              value: '2008-07',
                              onChanged: (_) {},
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final outlines = find.byWidgetPredicate(
                (widget) =>
                    widget is CustomPaint &&
                    widget.foregroundPainter?.runtimeType.toString() ==
                        '_InputBorderPainter',
              );
              double height(String key) => tester
                  .getSize(
                    find.descendant(
                      of: find.byKey(ValueKey(key)),
                      matching: outlines,
                    ),
                  )
                  .height;
              for (final key in [
                'info',
                'dropdown',
                'disabled',
                'native',
                'selected',
                'error',
                'date',
                'month',
              ]) {
                expect(height(key), closeTo(height('plain'), .5), reason: key);
              }
              if (scale == 1) {
                expect(height('plain'), touch && controlTheme ? 48 : 44);
              }
              if (const bool.fromEnvironment('UI_CAPTURE') &&
                  controlTheme &&
                  !touch &&
                  scale == 1) {
                await tester.runAsync(() async {
                  final boundary =
                      capture.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary;
                  final picture = await boundary.toImage();
                  final bytes = await picture.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final file = File(
                    '.local-artifacts/internal-feedback-ui/form-${dark ? 'dark' : 'light'}.png',
                  );
                  await file.parent.create(recursive: true);
                  await file.writeAsBytes(bytes!.buffer.asUint8List());
                  picture.dispose();
                });
              }
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }
}
