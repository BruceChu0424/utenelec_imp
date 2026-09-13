import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/feedback/uten_module_todo_chip.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';

void main() {
  testWidgets(
    'module todo matches permission action height and corner radius',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                const UtenModuleTodoChip(count: 6),
                UtenAppBarActionButton(
                  label: '权限设置',
                  icon: Icons.admin_panel_settings_outlined,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      );
      final chip = find.byKey(const ValueKey('uten-module-todo-chip'));
      expect(tester.getSize(chip).height, UtenAppBarActionButton.height);
      final container = tester.widget<Container>(chip);
      expect(
        (container.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(UtenRadius.control),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('zero module todo takes no space', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UtenModuleTodoChip(count: 0)),
    );
    expect(find.byKey(const ValueKey('uten-module-todo-chip')), findsNothing);
  });
}
