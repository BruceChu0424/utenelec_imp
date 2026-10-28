import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_panel_header.dart';
import 'package:uten_imp/components/layout/uten_section_header.dart';

const _title = '仓库范围';
const _message = '选择主仓时包含自身和全部子仓。这里只说明查询范围，实际仓库权限和数据仍按当前登录员工授权计算。';

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 380, child: child),
    ),
  ),
);

void main() {
  final headings = <String, Widget Function()>{
    'section': () => const UtenSectionHeader(title: _title, info: _message),
    'panel': () => UtenPanelHeader(
      title: _title,
      subtitle: '当前查看：成品仓',
      info: _message,
      onClose: () {},
    ),
  };
  for (final entry in headings.entries) {
    for (final interaction in ['hover', 'tap', 'keyboard']) {
      testWidgets(
        '${entry.key} heading exposes complete help by $interaction without a subtitle help row',
        (tester) async {
          await tester.pumpWidget(_app(entry.value()));
          await tester.pumpAndSettle();
          expect(find.text(_message), findsNothing);
          final title = tester.getRect(find.text(_title));
          final hint = tester.getRect(find.byType(UtenFieldHintIcon));
          expect(hint.left, greaterThanOrEqualTo(title.right));
          expect((hint.center.dy - title.center.dy).abs(), lessThan(2));
          if (interaction == 'hover') {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: const Offset(700, 500));
            await mouse.moveTo(hint.center);
            await tester.pump(const Duration(milliseconds: 251));
            await tester.pumpAndSettle();
            expect(find.text(_message), findsOneWidget);
            await mouse.removePointer();
          } else if (interaction == 'tap') {
            await tester.tap(find.byType(UtenFieldHintIcon));
            await tester.pumpAndSettle();
            expect(find.text(_message), findsOneWidget);
          } else {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.text(_message), findsOneWidget);
          }
          if (entry.key == 'panel') {
            expect(find.text('当前查看：成品仓'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'filter placeholder keeps the primary instruction and discloses its exact custom description',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const UtenFilterPlaceholder(
            message: '选择单据类型后开始办理',
            description: _message,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择单据类型后开始办理'), findsOneWidget);
      expect(find.text(_message), findsNothing);
      final heading = tester.getRect(find.text('选择单据类型后开始办理'));
      final hint = tester.getRect(find.byType(UtenFieldHintIcon));
      expect((heading.center.dy - hint.center.dy).abs(), lessThan(16));
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text(_message), findsOneWidget);
      expect(find.text('选择单据类型后开始办理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
