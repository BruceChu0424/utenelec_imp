import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/shared/repositories/account_history_store.dart';

class _History extends AccountHistoryStore {
  _History() : super(SecureStorage(const FlutterSecureStorage()));
  final accounts = ['recent-account', 'older-account'];

  @override
  Future<List<String>> getAll() async => List.of(accounts);

  @override
  Future<void> remove(String account) async => accounts.remove(account);

  @override
  Future<void> clear() async => accounts.clear();
}

Future<void> _mount(
  WidgetTester tester, {
  required _History history,
  required TextEditingController controller,
  required FocusNode passwordFocus,
  required VoidCallback onLogin,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [accountHistoryProvider.overrideWithValue(history)],
      child: MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 320,
              child: Column(
                children: [
                  AccountField(controller: controller, hint: '账号'),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('password'),
                    focusNode: passwordFocus,
                    decoration: const InputDecoration(labelText: '密码'),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: onLogin, child: const Text('登录')),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(AccountField));
  await tester.pumpAndSettle();
  expect(find.text('older-account'), findsOneWidget);
}

void main() {
  testWidgets('历史打开时首次点击外部登录按钮即可提交并关闭浮层', (tester) async {
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    var submits = 0;
    await _mount(
      tester,
      history: _History(),
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () => submits++,
    );
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(submits, 1, reason: '关闭历史不应吞掉同一次登录点击');
    expect(find.text('older-account'), findsNothing);
    expect(controller.text, 'recent-account');
  });

  testWidgets('键盘或程序移焦到密码时关闭历史', (tester) async {
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    await _mount(
      tester,
      history: _History(),
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () {},
    );
    passwordFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(passwordFocus.hasFocus, isTrue);
    expect(find.text('older-account'), findsNothing);
  });

  testWidgets('候选按下跨帧再松手仍可选择，光标停在账号末尾', (tester) async {
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    await _mount(
      tester,
      history: _History(),
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () {},
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('older-account')),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('older-account'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.text, 'older-account');
    expect(controller.selection.baseOffset, 'older-account'.length);
    expect(find.text('清除全部'), findsNothing);
  });

  testWidgets('删除后刷新可见历史，清除全部关闭浮层且不改当前输入', (tester) async {
    final history = _History();
    final controller = TextEditingController();
    final passwordFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(passwordFocus.dispose);
    await _mount(
      tester,
      history: history,
      controller: controller,
      passwordFocus: passwordFocus,
      onLogin: () {},
    );
    await tester.tap(find.byTooltip('删除').last);
    await tester.pumpAndSettle();
    expect(history.accounts, ['recent-account']);
    expect(find.text('older-account'), findsNothing);
    expect(find.text('清除全部'), findsOneWidget);
    await tester.tap(find.text('清除全部'));
    await tester.pumpAndSettle();
    expect(history.accounts, isEmpty);
    expect(find.text('清除全部'), findsNothing);
    expect(controller.text, 'recent-account');
  });
}
