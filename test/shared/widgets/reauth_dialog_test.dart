// 统一再认证弹窗 (ADR-110)：输对换凭证关闭；输错留在框里提示可重试；
// 连续输错到上限后不能再输；空密码不发请求；取消返回 null。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';

void main() {
  testWidgets('输对密码：拿到凭证并关闭弹窗', (tester) async {
    final verified = <String>[];
    final result = await _open(tester, (password) async {
      verified.add(password);
      return 'one-time-token';
    });

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('reauth-password')),
        matching: find.byType(EditableText),
      ),
      'CorrectPassword1',
    );
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();

    expect(verified, ['CorrectPassword1']);
    expect(find.byKey(const Key('reauth-dialog')), findsNothing);
    expect(await result, 'one-time-token');
  });

  testWidgets('输错：留在框里提示服务端原因，可以再试', (tester) async {
    var calls = 0;
    await _open(tester, (password) async {
      calls++;
      if (calls == 1) {
        throw ApiException('REAUTH_FAILED', '密码不正确，还可以再试 4 次');
      }
      return 'token-after-retry';
    });

    final input = find.descendant(
      of: find.byKey(const Key('reauth-password')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(input, 'wrong');
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
    expect(find.text('密码不正确，还可以再试 4 次'), findsOneWidget);

    await tester.enterText(input, 'right');
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.byKey(const Key('reauth-dialog')), findsNothing);
  });

  testWidgets('连续输错到上限：提示暂停，输入框与确认按钮都不可用', (tester) async {
    var calls = 0;
    await _open(tester, (password) async {
      calls++;
      throw ApiException('REAUTH_LOCKED', '密码输错次数过多，请 15 分钟后再试');
    });

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('reauth-password')),
        matching: find.byType(EditableText),
      ),
      'wrong',
    );
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('密码输错次数过多，请 15 分钟后再试'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('空密码不发请求；取消返回 null', (tester) async {
    var calls = 0;
    final result = await _open(tester, (password) async {
      calls++;
      return 'token';
    });

    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('请输入登录密码'), findsOneWidget);
    expect(calls, 0);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}

/// 打开弹窗并返回它的结果 future (弹窗关闭时完成)。
Future<Future<String?>> _open(
  WidgetTester tester,
  Future<String> Function(String password) verify,
) async {
  final completer = Completer<String?>();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                completer.complete(
                  await showReauthDialog(context, verify: verify),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
  return completer.future;
}
