import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_table_read_status.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';

typedef _ReadState = ({
  bool visible,
  String owner,
  String reason,
  bool loading,
  int callback,
});

const _initial = (
  visible: true,
  owner: 'account-A/server-A/query-A',
  reason: '首次读取失败的完整原因',
  loading: false,
  callback: 0,
);

Future<void> _mount(
  WidgetTester tester,
  ValueNotifier<_ReadState> source,
  List<int> retries,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<_ReadState>(
          valueListenable: source,
          builder: (_, state, _) => state.visible
              ? UtenTableReadStatus(
                  ownerIdentity: state.owner,
                  title: '数据加载失败',
                  reason: state.reason,
                  loading: state.loading,
                  keyPrefix: 'lifecycle-read',
                  retry: () => retries.add(state.callback),
                )
              : const Text('失败已经恢复或原表已离开'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<UtenButton> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('lifecycle-read-details')));
  await tester.pumpAndSettle();
  expect(find.byType(UtenAlertDialog), findsOneWidget);
  return tester.widget<UtenButton>(
    find
        .ancestor(
          of: find.descendant(
            of: find.byType(UtenAlertDialog),
            matching: find.text('重试'),
          ),
          matching: find.byType(UtenButton),
        )
        .first,
  );
}

void main() {
  for (final boundary in ['owner', 'reason', 'loading', 'recovery']) {
    testWidgets(
      '$boundary change retires details and invalidates stale retry',
      (tester) async {
        final source = ValueNotifier<_ReadState>(_initial);
        addTearDown(source.dispose);
        final retries = <int>[];
        await _mount(tester, source, retries);
        final oldRetry = await _open(tester);
        source.value = (
          visible: boundary != 'recovery',
          owner: boundary == 'owner'
              ? 'account-B/server-B/query-B'
              : _initial.owner,
          reason: boundary == 'reason' ? '另一条读取失败的原因' : _initial.reason,
          loading: boundary == 'loading',
          callback: 1,
        );
        await tester.pump();
        // Even a previously retained action callback must become inert before
        // the route's remaining exit frames can receive an old pointer event.
        await oldRetry.onPressed!();
        await tester.pump(const Duration(milliseconds: 400));
        expect(retries, isEmpty);
        expect(find.byType(UtenAlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        if (boundary == 'owner' || boundary == 'reason') {
          final currentRetry = await _open(tester);
          await currentRetry.onPressed!();
          await tester.pumpAndSettle();
          expect(retries, [1]);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'fresh callbacks for the same owner retain details and use latest retry',
    (tester) async {
      final source = ValueNotifier<_ReadState>(_initial);
      addTearDown(source.dispose);
      final retries = <int>[];
      await _mount(tester, source, retries);
      final retry = await _open(tester);
      source.value = (
        visible: true,
        owner: _initial.owner,
        reason: _initial.reason,
        loading: false,
        callback: 7,
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsOneWidget);
      await retry.onPressed!();
      await tester.pumpAndSettle();
      expect(retries, [7]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing the owner removes only its route beneath a newer modal',
    (tester) async {
      final source = ValueNotifier<_ReadState>(_initial);
      addTearDown(source.dispose);
      final retries = <int>[];
      await _mount(tester, source, retries);
      final retry = await _open(tester);
      final context = tester.element(find.byType(UtenAlertDialog));
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('后续对话框'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭后续对话框'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      source.value = (
        visible: false,
        owner: _initial.owner,
        reason: _initial.reason,
        loading: false,
        callback: 1,
      );
      await tester.pumpAndSettle();
      await retry.onPressed!();
      await tester.pumpAndSettle();
      expect(retries, isEmpty);
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(find.text('后续对话框'), findsOneWidget);
      await tester.tap(find.text('关闭后续对话框'));
      await tester.pumpAndSettle();
      expect(find.text('后续对话框'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
