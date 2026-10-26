// 再认证框必须压在忙碌遮罩之上、能真正点到 (ADR-110 评审阻断项)。
//
// 部门权限保存、个人权限覆盖、数据范围、系统设置等写操作先挂整页忙碌遮罩再发请求；
// 服务端回 403 REAUTH_REQUIRED 后网络层在根导航器上弹统一密码框。忙碌遮罩是 root Overlay 里的
// 裸 OverlayEntry，导航器推路由会把它抬回最顶层——若不让位，密码框被遮罩整片盖住，请求等密码、
// 遮罩等请求，整页卡死。宿主照搬页面写法 (AbsorbPointer + UtenBusyOverlay)，全部按坐标点击。
// 2026-10-25：共享遮罩增加所属路由生命周期保护，直接弹出的密码框同样自动让位；
// 显式 yieldWhile 保留为兼容入口，两条路径都必须在返回后恢复仍在运行的任务遮罩。
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

  testWidgets('无需主动让位直接弹框也能输入确认，旧页面遮罩按路由自动恢复', (tester) async {
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

    expect(find.text('正在保存部门权限'), findsNothing);
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reauth-confirm'))),
    );
    await _frames(tester);

    expect(find.text('请输入登录密码'), findsOneWidget, reason: '确认按钮可以到达，正常提示必填密码');
    expect(verifyCalls, 0);
    expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
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
    expect(verifyCalls, 1);
    expect(find.byKey(const Key('reauth-dialog')), findsNothing);
    expect(find.text('正在保存部门权限'), findsOneWidget);
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
