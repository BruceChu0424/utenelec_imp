import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/feedback/uten_tooltip_navigation_host.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';

void main() {
  testWidgets(
    'kept-alive help is dismissed after declarative route navigation',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/first',
        routes: [
          ShellRoute(
            builder: (_, state, child) => Scaffold(
              body: IndexedStack(
                index: state.uri.path == '/first' ? 0 : 1,
                children: const [
                  UtenFieldHintIcon(info: '只属于第一页的完整帮助'),
                  Text('第二页'),
                ],
              ),
            ),
            routes: [
              GoRoute(path: '/first', builder: (_, _) => const SizedBox()),
              GoRoute(path: '/second', builder: (_, _) => const SizedBox()),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => UtenTooltipNavigationHost(
            navigation: router.routerDelegate,
            child: child!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text('只属于第一页的完整帮助'), findsOneWidget);
      router.go('/second');
      await tester.pumpAndSettle();
      expect(find.text('第二页'), findsOneWidget);
      expect(find.text('只属于第一页的完整帮助'), findsNothing);
      expect(
        find.byType(UtenFieldHintIcon, skipOffstage: false),
        findsOneWidget,
      );
      router.go('/first');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text('只属于第一页的完整帮助'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
