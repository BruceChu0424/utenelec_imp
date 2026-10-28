import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/features/admin/widgets/system_updater_status_card.dart';

const _policy = '保存后需等待服务器确认。这里仅查看服务器状态，不会触发云端检查或下载。';

void main() {
  for (final interaction in ['hover', 'tap']) {
    testWidgets(
      'updater guidance opens by $interaction while failure stays visible',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 390,
                child: SystemUpdaterStatusCard(
                  status: null,
                  loading: false,
                  error: '连接中断，请刷新后重试',
                  onRefresh: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_policy), findsNothing);
        expect(find.text('更新状态读取失败'), findsOneWidget);
        expect(find.text('连接中断，请刷新后重试'), findsOneWidget);
        final hint = find.byType(UtenFieldHintIcon);
        final heading = tester.getRect(find.text('更新状态读取失败'));
        expect(tester.getCenter(hint).dy, closeTo(heading.center.dy, 10));
        if (interaction == 'hover') {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(700, 500));
          await mouse.moveTo(tester.getCenter(hint));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(find.text(_policy), findsOneWidget);
          await mouse.removePointer();
        } else {
          await tester.tap(hint);
          await tester.pumpAndSettle();
          expect(find.text(_policy), findsOneWidget);
        }
        expect(find.text('连接中断，请刷新后重试'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
