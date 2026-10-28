import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_dialog_modules.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  testWidgets(
    'setting cards retain one native control and focus across narrow wrapping',
    (tester) async {
      final width = ValueNotifier<double>(360);
      final focus = FocusNode();
      addTearDown(width.dispose);
      addTearDown(focus.dispose);
      var enabled = false;
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => ValueListenableBuilder<double>(
                  valueListenable: width,
                  builder: (context, value, _) => SizedBox(
                    width: value,
                    child: UtenDialogSettingTile(
                      canRequestFocus: false,
                      icon: Icons.shield_outlined,
                      title: const Text('设置密码'),
                      subtitle: const Text('保留原生控件的键盘焦点和完整说明'),
                      onTap: () => setState(() {
                        enabled = !enabled;
                        changes++;
                      }),
                      trailing: Switch(
                        focusNode: focus,
                        value: enabled,
                        onChanged: (next) => setState(() {
                          enabled = next;
                          changes++;
                        }),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = tester.element(find.byType(Switch));
      focus.requestFocus();
      await tester.pump();
      for (final value in [112.0, 360.0]) {
        width.value = value;
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(Switch)), same(original));
        expect(focus.hasFocus, isTrue);
        expect(find.byType(Switch).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
      expect(changes, 1);
    },
  );

  testWidgets('native radio cards preserve grouped arrow navigation', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => RadioGroup<int>(
              groupValue: selected,
              onChanged: (value) => setState(() => selected = value!),
              child: Column(
                children: [
                  for (var index = 0; index < 2; index++)
                    UtenDialogSettingTile(
                      canRequestFocus: false,
                      icon: Icons.description_outlined,
                      title: Text('处理方式 $index'),
                      selected: selected == index,
                      onTap: () => setState(() => selected = index),
                      trailing: Radio<int>(value: index),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(selected, 1);
    await tester.tap(find.text('处理方式 0'));
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    testWidgets(
      'choice cards support keyboard selection and large text dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var selected = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: StatefulBuilder(
                  builder: (context, setState) => UtenDialogOptionCard(
                    icon: Icons.note_add_outlined,
                    title: const Text('新建货品'),
                    subtitle: const Text('全部新建，保留文件中的分类'),
                    selected: selected,
                    onTap: () => setState(() => selected = true),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, isTrue);
        expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
