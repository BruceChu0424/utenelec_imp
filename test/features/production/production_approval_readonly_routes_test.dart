import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/production/production_routes.dart';

void main() {
  for (final family in ['plans', 'daily-reports']) {
    testWidgets('old $family approval edit link opens readonly detail', (
      tester,
    ) async {
      final editor = productionRoutes.whereType<GoRoute>().singleWhere(
        (route) => route.path == '/production/$family/:id/edit',
      );
      var editorOpened = false;
      final router = GoRouter(
        initialLocation: '/production/$family/doc-1/edit?review=1',
        routes: [
          GoRoute(
            path: editor.path,
            redirect: editor.redirect,
            builder: (_, _) {
              editorOpened = true;
              return const Scaffold(body: Text('可编辑表单'));
            },
          ),
          GoRoute(
            path: '/production/$family/:id',
            builder: (_, state) =>
                Scaffold(body: Text('只读详情 ${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(editorOpened, isFalse);
      expect(find.text('只读详情 doc-1'), findsOneWidget);
      expect(find.text('可编辑表单'), findsNothing);
    });
  }
}
