import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  testWidgets(
    'native and shared header actions show button labels without icons',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            appBar: UtenAppBar(
              title: '操作',
              showPagePermissionAction: false,
              actions: [
                IconButton(
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => calls++,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.inventory_2),
                  label: const Text('车间内料仓'),
                  onPressed: () => calls++,
                ),
                UtenButton(
                  icon: Icons.add,
                  type: UtenButtonType.ghost,
                  onPressed: () => calls++,
                  child: const Text('新建'),
                ),
                UtenAppBarActionButton(
                  label: '权限设置',
                  icon: Icons.security,
                  compact: true,
                  onPressed: () => calls++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = find.byType(AppBar);
      expect(
        find.descendant(of: bar, matching: find.byType(Icon)),
        findsNothing,
      );
      for (final label in ['刷新', '车间内料仓', '新建', '权限设置']) {
        expect(find.text(label), findsOneWidget);
        await tester.tap(find.text(label));
      }
      expect(calls, 4);
      expect(tester.takeException(), isNull);
    },
  );
}
