// 再认证框必须压在忙碌遮罩之上、能真正点到 (ADR-110 评审阻断项)。
//
// 部门权限保存、个人权限覆盖、数据范围、清空业务数据、清理测试附件等写操作先挂整页忙碌遮罩再发请求；
// 服务端回 403 REAUTH_REQUIRED 后网络层在根导航器上弹统一密码框。忙碌遮罩是 root Overlay 里的
// 裸 OverlayEntry，导航器推路由会把它抬回最顶层——若不让位，密码框被遮罩整片盖住，请求等密码、
// 遮罩等请求，整页卡死。宿主照搬页面写法 (AbsorbPointer + UtenBusyOverlay)，全部按坐标点击。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';

void main() {
  testWidgets('忙碌遮罩在场时: 密码框可按坐标输入与确认, 关框后遮罩恢复', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_host(navigatorKey));
    await _frames(tester);
    expect(find.text('正在保存部门权限'), findsOneWidget);

    final verified = <String>[];
    final result = showReauthDialog(
      navigatorKey.currentContext!,
      verify: (password) async {
        verified.add(password);
        return 'one-time-token';
      },
    );
    await _frames(tester);

    expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
    expect(find.text('正在保存部门权限'), findsNothing, reason: '弹框期间遮罩让位');

    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-password'))),
    );
    await tester.pump();
    tester.testTextInput.enterText('CorrectPassword1');
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-confirm'))),
    );
    await _frames(tester);

    expect(verified, ['CorrectPassword1']);
    expect(await result, 'one-time-token');
    expect(find.byKey(const Key('reauth-dialog')), findsNothing);
    expect(
      find.text('正在保存部门权限'),
      findsOneWidget,
      reason: '关框后遮罩恢复, 直到带凭证重发的请求结束',
    );
  });

  testWidgets('对照: 不让位直接弹框时遮罩盖在密码框之上, 点确认没有反应 (原卡死现场)', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_host(navigatorKey));
    await _frames(tester);

    var verifyCalls = 0;
    unawaited(
      showDialog<String>(
        context: navigatorKey.currentContext!,
        barrierDismissible: false,
        builder: (_) => ReauthDialog(
          verify: (password) async {
            verifyCalls++;
            return 'token';
          },
        ),
      ),
    );
    await _frames(tester);

    expect(find.text('正在保存部门权限'), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-confirm'))),
    );
    await _frames(tester);

    expect(find.text('请输入登录密码'), findsNothing, reason: '点击落在遮罩上, 没到确认按钮');
    expect(verifyCalls, 0);
    expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
  });
}

Widget _host(GlobalKey<NavigatorState> navigatorKey) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    home: const Scaffold(
      body: Stack(
        children: [
          AbsorbPointer(child: Center(child: Text('部门权限'))),
          UtenBusyOverlay(title: '正在保存部门权限'),
        ],
      ),
    ),
  );
}

/// 遮罩里的进度圈一直在转, 不能 pumpAndSettle; 固定推进若干帧。
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
