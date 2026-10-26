import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Future<void> _source(
  WidgetTester tester, {
  required List<bool> fullscreenChanges,
  required VoidCallback onDetailAction,
}) async {
  final root = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: root,
    initialLocation: '/goods',
    routes: [
      ShellRoute(
        builder: (_, _, child) => Scaffold(body: child),
        routes: [
          GoRoute(
            path: '/goods',
            builder: (context, _) => Scaffold(
              body: MasterDataTableView<String>(
                columns: [
                  MasterColumnDef<String>(
                    key: 'name',
                    label: '货品名称',
                    width: 260,
                    value: (row) => row,
                  ),
                ],
                items: const ['业务货品'],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                onRowTap: (_) => context.push('/goods/detail'),
                onFullscreenChanged: fullscreenChanges.add,
                toolbarActions: [
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: root.currentContext!,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('普通打印预览'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            child: const Text('关闭预览'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('打开预览'),
                  ),
                  TextButton(
                    onPressed: () => context.go('/other'),
                    child: const Text('离开资料'),
                  ),
                ],
              ),
            ),
            routes: [
              GoRoute(
                path: 'detail',
                builder: (context, _) => Scaffold(
                  appBar: AppBar(title: const Text('货品详情')),
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: onDetailAction,
                          child: const Text('详情操作'),
                        ),
                        TextButton(
                          onPressed: () => context.pop(),
                          child: const Text('返回货品资料'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/other',
            builder: (_, _) => Scaffold(
              appBar: AppBar(title: const Text('其他业务')),
              body: Center(
                child: TextButton(
                  onPressed: onDetailAction,
                  child: const Text('其他业务操作'),
                ),
              ),
            ),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  await tester.tap(find.text('全屏'));
  await tester.pumpAndSettle();
  expect(find.text('退出全屏'), findsOneWidget);
  expect(
    ModalRoute.of(tester.element(find.text('退出全屏')))?.barrierDismissible,
    isFalse,
    reason: '保留原showGeneralDialog的不可点遮罩关闭合同',
  );
}

void main() {
  testWidgets('Shell源表全屏双击进入子Navigator详情，精确撤下全屏且详情可操作', (tester) async {
    final fullscreenChanges = <bool>[];
    var detailActions = 0;
    await _source(
      tester,
      fullscreenChanges: fullscreenChanges,
      onDetailAction: () => detailActions++,
    );
    await tester.tap(find.text('业务货品'));
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tap(find.text('业务货品'));
    await tester.pumpAndSettle();
    expect(find.text('货品详情'), findsOneWidget);
    expect(find.text('退出全屏'), findsNothing);
    await tester.tapAt(tester.getCenter(find.text('详情操作')));
    await tester.pump();
    expect(detailActions, 1);
    await tester.tap(find.text('返回货品资料'));
    await tester.pumpAndSettle();
    expect(find.text('业务货品'), findsOneWidget);
    expect(find.text('全屏'), findsOneWidget);
    expect(fullscreenChanges, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通root预览对话框不离开源GoRouter页面，关闭后保留全屏', (tester) async {
    final fullscreenChanges = <bool>[];
    await _source(
      tester,
      fullscreenChanges: fullscreenChanges,
      onDetailAction: () {},
    );
    await tester.tap(find.text('打开预览'));
    await tester.pumpAndSettle();
    expect(find.text('普通打印预览'), findsOneWidget);
    expect(fullscreenChanges, [true]);
    await tester.tap(find.text('关闭预览'));
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(find.text('业务货品'), findsOneWidget);
    expect(fullscreenChanges, [true]);
    await tester.tap(find.text('退出全屏'));
    await tester.pumpAndSettle();
    expect(find.text('全屏'), findsOneWidget);
    expect(fullscreenChanges, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shell源表State在全屏中被go替换，dispose精确清理本次呈现', (tester) async {
    var actions = 0;
    await _source(
      tester,
      fullscreenChanges: [],
      onDetailAction: () => actions++,
    );
    await tester.tap(find.text('离开资料'));
    await tester.pumpAndSettle();
    expect(find.text('其他业务'), findsOneWidget);
    expect(find.text('退出全屏'), findsNothing);
    expect(find.byType(MasterDataTableView<String>), findsNothing);
    await tester.tapAt(tester.getCenter(find.text('其他业务操作')));
    await tester.pump();
    expect(actions, 1);
    expect(tester.takeException(), isNull);
  });
}
