import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/shared/repositories/account_history_store.dart';

class _History extends AccountHistoryStore {
  _History([List<String>? accounts])
    : accounts = List.of(accounts ?? ['recent-account', 'older-account']),
      super(SecureStorage(const FlutterSecureStorage()));

  final List<String> accounts;

  @override
  Future<List<String>> getAll() async => List.of(accounts);

  @override
  Future<void> remove(String account) async => accounts.remove(account);
}

Future<void> _mount(
  WidgetTester tester, {
  required TextEditingController controller,
  _History? history,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountHistoryProvider.overrideWithValue(history ?? _History()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: AccountField(controller: controller, hint: '账号'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(AccountField));
  await tester.pumpAndSettle();
  expect(tester.testTextInput.hasAnyClients, isTrue);
}

Future<void> _closeNativeEditorAcrossFrames(WidgetTester tester) async {
  // The Web engine sends this when its native text editor blurs. It is not
  // routed through TextFieldTapRegion and can arrive before mouse-up.
  tester.testTextInput.closeConnection();
  await tester.pump(const Duration(milliseconds: 80));
  // A second frame applies the OverlayEntry removal requested by the
  // post-frame focus callback. A single pump leaves the row mounted and
  // incorrectly allows its pending tap to succeed in a widget test.
  await tester.pump(const Duration(milliseconds: 80));
}

void main() {
  testWidgets('历史候选按下后 Web 文本连接关闭仍完成同一次账号选择', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _mount(tester, controller: controller);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.down(tester.getCenter(find.text('older-account')));
    await _closeNativeEditorAcrossFrames(tester);
    expect(controller.text, 'recent-account', reason: '按下不能提前选中，仍须允许滚动');
    await mouse.up();
    await tester.pumpAndSettle();

    expect(controller.text, 'older-account');
    expect(controller.selection.baseOffset, 'older-account'.length);
    expect(find.text('清除全部'), findsNothing);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
  });

  testWidgets('Web 文本连接关闭后删除候选仍只删除、不切换账号', (tester) async {
    final controller = TextEditingController();
    final history = _History();
    addTearDown(controller.dispose);
    await _mount(tester, controller: controller, history: history);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.down(tester.getCenter(find.byTooltip('删除').last));
    await _closeNativeEditorAcrossFrames(tester);
    expect(history.accounts, contains('older-account'));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(history.accounts, ['recent-account']);
    expect(controller.text, 'recent-account');
    expect(find.text('清除全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
  });

  testWidgets('Web 文本连接关闭后候选拖动仍可滚动且不误选账号', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _mount(
      tester,
      controller: controller,
      history: _History([
        'recent-account',
        for (var i = 1; i <= 9; i++) 'older-account-$i',
      ]),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('older-account-1')),
    );
    await _closeNativeEditorAcrossFrames(tester);
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, greaterThan(0));
    expect(controller.text, 'recent-account');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.text, 'recent-account');
    expect(find.text('清除全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Web 文本连接关闭后取消候选指针保持菜单且不选中', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _mount(tester, controller: controller);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('older-account')),
      kind: PointerDeviceKind.mouse,
    );
    await _closeNativeEditorAcrossFrames(tester);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(controller.text, 'recent-account');
    expect(find.text('清除全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
