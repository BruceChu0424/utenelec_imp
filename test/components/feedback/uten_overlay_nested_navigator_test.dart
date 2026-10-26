import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';

Future<({GlobalKey<NavigatorState> root, GlobalKey<NavigatorState> shell})>
_shell(WidgetTester tester, Widget child) async {
  final root = GlobalKey<NavigatorState>();
  final shell = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: root,
    initialLocation: '/goods',
    routes: [
      ShellRoute(
        navigatorKey: shell,
        builder: (_, _, child) => Scaffold(body: child),
        routes: [
          GoRoute(
            path: '/goods',
            builder: (_, _) => Scaffold(body: child),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      builder: (_, child) => UtenContextMenuPolicy(child: child!),
    ),
  );
  await _frames(tester);
  return (root: root, shell: shell);
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('Shell子页busy遇根Navigator透明对话框应让位，返回原页仍恢复', (tester) async {
    final navigators = await _shell(
      tester,
      const UtenBusyOverlay(title: '子页正在保存'),
    );
    expect(find.text('子页正在保存'), findsOneWidget);
    var confirmations = 0;
    showDialog<void>(
      context: navigators.root.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('根级确认'),
        actions: [
          TextButton(
            onPressed: () {
              confirmations++;
              Navigator.of(context).pop();
            },
            child: const Text('根级继续'),
          ),
        ],
      ),
    );
    await _frames(tester);
    await tester.tapAt(tester.getCenter(find.text('根级继续')));
    await _frames(tester);
    expect(confirmations, 1, reason: '不能只检查Shell子Navigator中仍为current的资料route');
    expect(find.text('根级确认'), findsNothing);
    expect(find.text('子页正在保存'), findsOneWidget);
  });

  testWidgets('Shell子页行菜单遇根Navigator透明对话框应关闭', (tester) async {
    final navigators = await _shell(
      tester,
      UtenContextMenuRegion(
        entriesBuilder: () => [UtenMenuItem(label: '子页行操作', onTap: () {})],
        child: const Center(child: Text('子页货品')),
      ),
    );
    final pointer = await tester.startGesture(
      tester.getCenter(find.text('子页货品')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await pointer.up();
    await _frames(tester);
    expect(find.text('子页行操作'), findsOneWidget);
    showDialog<void>(
      context: navigators.root.currentContext!,
      builder: (_) => const AlertDialog(title: Text('根级提醒')),
    );
    await _frames(tester);
    expect(find.text('子页行操作'), findsNothing);
    expect(find.text('根级提醒'), findsOneWidget);
  });

  testWidgets('Shell子页下拉菜单遇rootDialog关闭，返回后仍能重新选择', (tester) async {
    const field = ValueKey('shell-dropdown');
    final values = <String?>[];
    final navigators = await _shell(
      tester,
      SizedBox(
        width: 300,
        child: UtenDropdownField(
          key: field,
          value: null,
          items: const [
            UtenDropdownItem(value: 'a', label: '仓库A'),
            UtenDropdownItem(value: 'b', label: '仓库B'),
          ],
          searchable: false,
          allowClear: false,
          onChanged: values.add,
        ),
      ),
    );
    final option = find.byKey(
      const ValueKey<(String, Key?, String?)>((
        'uten-dropdown-option',
        field,
        'b',
      )),
    );
    await tester.tap(find.byKey(field));
    await _frames(tester);
    expect(option, findsOneWidget);
    showDialog<void>(
      context: navigators.root.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('仓库选择期间的根级提醒'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭提醒'),
          ),
        ],
      ),
    );
    await _frames(tester);
    expect(option, findsNothing);
    await tester.tapAt(tester.getCenter(find.text('关闭提醒')));
    await _frames(tester);
    await tester.tap(find.byKey(field));
    await _frames(tester);
    await tester.tap(option);
    await _frames(tester);
    expect(values, ['b']);
    expect(option, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final useRoot in [true, false]) {
    testWidgets('Shell页面上${useRoot ? '根' : '子'}Navigator对话框自己的busy仍阻止重复操作', (
      tester,
    ) async {
      final navigators = await _shell(
        tester,
        const UtenBusyOverlay(title: '子页正在保存'),
      );
      var dialogBusy = true;
      var confirmations = 0;
      late StateSetter change;
      showDialog<void>(
        context: navigators.shell.currentContext!,
        useRootNavigator: useRoot,
        builder: (dialogContext) => StatefulBuilder(
          builder: (_, setState) {
            change = setState;
            return Stack(
              children: [
                AlertDialog(
                  title: const Text('对话框自己的业务'),
                  actions: [
                    TextButton(
                      onPressed: () {
                        confirmations++;
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text('对话框完成'),
                    ),
                  ],
                ),
                if (dialogBusy) const UtenBusyOverlay(title: '对话框正在处理'),
              ],
            );
          },
        ),
      );
      await _frames(tester);
      expect(find.text('子页正在保存'), findsNothing);
      expect(find.text('对话框正在处理'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.text('对话框完成')));
      await _frames(tester);
      expect(confirmations, 0);
      change(() => dialogBusy = false);
      await _frames(tester);
      await tester.tapAt(tester.getCenter(find.text('对话框完成')));
      await _frames(tester);
      expect(confirmations, 1);
      expect(find.text('对话框自己的业务'), findsNothing);
      expect(find.text('子页正在保存'), findsOneWidget);
    });
  }
}
