import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_app_bar_action_scope.dart';
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
                TextButton(
                  child: const Text('车间内料仓'),
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

  testWidgets(
    'explicit public native label preserves state and callbacks without icon spacing',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final focus = FocusNode();
      final states = WidgetStatesController();
      addTearDown(focus.dispose);
      addTearDown(states.dispose);
      var taps = 0;
      var longPresses = 0;
      final native = TextButton.icon(
        focusNode: focus,
        statesController: states,
        icon: const Icon(Icons.inventory_2),
        label: const Text('Private factory child must not be built'),
        onPressed: () => taps++,
        onLongPress: () => longPresses++,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            appBar: UtenAppBar(
              title: '公开标签',
              showPagePermissionAction: false,
              actions: [
                UtenAppBarNativeActionButton(
                  key: const Key('explicit-native-label'),
                  source: native,
                  label: const Text('车间内料仓'),
                  onPressed: native.onPressed,
                  onLongPress: native.onLongPress,
                ),
                TextButton(
                  key: const Key('plain-native-label'),
                  onPressed: () {},
                  child: const Text('车间内料仓'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final explicit = find.byKey(const Key('explicit-native-label'));
      final plain = find.byKey(const Key('plain-native-label'));
      expect(tester.getSize(explicit).width, tester.getSize(plain).width);
      expect(
        find.text('Private factory child must not be built'),
        findsNothing,
      );
      expect(
        find.descendant(of: explicit, matching: find.byType(Icon)),
        findsNothing,
      );
      final presented = tester.widget<UtenAppBarNativeActionButton>(explicit);
      expect(presented.focusNode, same(focus));
      expect(presented.statesController, same(states));
      final context = tester.element(explicit);
      final style = presented.defaultStyleOf(context);
      expect(
        style.backgroundColor?.resolve({}),
        Theme.of(context).colorScheme.primary,
      );
      expect(style.minimumSize?.resolve({}), const Size(36, 36));
      await tester.tap(explicit);
      await tester.longPress(explicit);
      expect(taps, 1);
      expect(longPresses, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
