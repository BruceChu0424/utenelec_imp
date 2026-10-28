import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/shared/providers/session_kick_notice_host.dart';

void main() {
  testWidgets('被顶号时在登录页上弹出「当前设备已下线」并说明来源设备', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SessionKickNoticeHost()));

    SessionEventBus.instance.expire(
      const SessionExpiryNotice.replaced('账号已在「网页端 · Chrome」登录，本设备已自动下线'),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前设备已下线'), findsOneWidget);
    expect(find.text('账号已在「网页端 · Chrome」登录，本设备已自动下线'), findsOneWidget);
    expect(find.textContaining('同一账号同时只能在一处在线'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('当前设备已下线'), findsNothing);
  });

  testWidgets('非顶号的普通失效不弹说明弹窗', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SessionKickNoticeHost()));

    SessionEventBus.instance.expire(const SessionExpiryNotice.other());
    await tester.pumpAndSettle();

    expect(find.text('当前设备已下线'), findsNothing);
  });

  testWidgets('重复的顶号事件只弹一次', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SessionKickNoticeHost()));

    SessionEventBus.instance.expire(
      const SessionExpiryNotice.replaced('账号已在「Windows 客户端」登录，本设备已自动下线'),
    );
    await tester.pump();
    SessionEventBus.instance.expire(
      const SessionExpiryNotice.replaced('账号已在「Windows 客户端」登录，本设备已自动下线'),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前设备已下线'), findsOneWidget);
  });
}
