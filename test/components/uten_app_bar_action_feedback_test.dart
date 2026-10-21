import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

Future<void> _mount(
  WidgetTester tester,
  List<Widget> actions, {
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
      home: Scaffold(
        appBar: UtenAppBar(
          title: '页面操作',
          showPagePermissionAction: false,
          actions: actions,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _paintedButton(WidgetTester tester, String label) => tester.getRect(
  find.ancestor(of: find.text(label), matching: find.byType(Material)).first,
);

class _HiddenAction extends StatelessWidget {
  const _HiddenAction();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets(
    'mixed and grouped visible actions all have the same painted 4px gap',
    (tester) async {
      await _mount(tester, [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextButton(onPressed: () {}, child: const Text('原生')),
        ),
        const SizedBox(width: 12),
        const _HiddenAction(),
        UtenButton(onPressed: () {}, child: const Text('通用')),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenAppBarActionButton(label: '顶栏', onPressed: () {}),
            const SizedBox(width: 8),
            UtenButton(onPressed: () {}, child: const Text('分组')),
          ],
        ),
        UtenRefreshButton(onRefresh: () async {}),
      ]);
      final rects = [
        for (final label in ['原生', '通用', '顶栏', '分组', '刷新'])
          _paintedButton(tester, label),
      ];
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i].left - rects[i - 1].right, closeTo(4, 0.1));
        expect(rects[i].center.dy, closeTo(rects.first.center.dy, 0.1));
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['native', 'shared', 'header', 'refresh']) {
    testWidgets(
      '$kind waits for its request with stable width and blocks repeat clicks',
      (tester) async {
        final done = Completer<void>();
        var calls = 0;
        Future<void> run() async {
          calls++;
          await done.future;
        }

        final Widget action = switch (kind) {
          'native' => TextButton(onPressed: run, child: const Text('刷新')),
          'shared' => UtenButton(onPressed: run, child: const Text('刷新')),
          'header' => UtenAppBarActionButton(label: '刷新', onPressed: run),
          _ => UtenRefreshButton(onRefresh: run),
        };
        await _mount(tester, [
          action,
          UtenAppBarActionButton(label: '下一项', onPressed: () {}),
        ]);
        final original = _paintedButton(tester, '刷新');
        final next = _paintedButton(tester, '下一项');
        await tester.tap(find.text('刷新'));
        await tester.pump();
        expect(calls, 1);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(_paintedButton(tester, '刷新'), original);
        expect(_paintedButton(tester, '下一项'), next);
        await tester.tapAt(original.center);
        await tester.pump();
        expect(calls, 1);
        done.complete();
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(_paintedButton(tester, '刷新'), original);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('an unrelated disabled refresh shows no false loading state', (
    tester,
  ) async {
    var calls = 0;
    await _mount(tester, [
      UtenRefreshButton(enabled: false, onRefresh: () => calls++),
    ]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('刷新'));
    await tester.pump();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  for (final kind in ['shared', 'header']) {
    testWidgets(
      '$kind dialog is the response while its covered header stops animating',
      (tester) async {
        var calls = 0;
        await _mount(tester, [
          Builder(
            builder: (context) {
              Future<void> openDialog() {
                calls++;
                return showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('业务确认'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                );
              }

              return kind == 'shared'
                  ? UtenButton(onPressed: openDialog, child: const Text('打开确认'))
                  : UtenAppBarActionButton(
                      label: '打开确认',
                      onPressed: openDialog,
                    );
            },
          ),
        ]);
        await tester.tap(find.text('打开确认'));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.text('业务确认'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.text('打开确认'));
        await tester.pumpAndSettle();
        expect(
          calls,
          2,
          reason: 'closing the dialog releases the action guard',
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an in-flight header can be removed before its request completes',
    (tester) async {
      final done = Completer<void>();
      await _mount(tester, [
        UtenAppBarActionButton(label: '请求', onPressed: () => done.future),
      ]);
      await tester.tap(find.text('请求'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      done.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
