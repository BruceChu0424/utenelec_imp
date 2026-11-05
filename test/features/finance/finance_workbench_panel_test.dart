import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/features/finance/shared/finance_workbench_panel.dart';

void main() {
  testWidgets(
    'side panel keeps the report context, isolates nested dialogs and returns its original result',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? result;
      await _mount(tester, onResult: (value) => result = value);
      await tester.tap(find.text('打开资料'));
      await tester.pumpAndSettle();
      final panel = tester.getRect(
        find.byKey(const ValueKey('workbench-body')),
      );
      expect(panel.right, 1280);
      expect(panel.left, 320);
      expect(panel.height, 900);
      expect(find.byType(Dialog), findsNothing);
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workbench-body')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workbench-body')), findsOneWidget);
      await tester.tap(find.text('核对选项'));
      await tester.pumpAndSettle();
      final modal = tester.getRect(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(modal.width, lessThan(700));
      expect(modal.center.dx, 640);
      await tester.tap(find.text('返回资料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存原资料'));
      await tester.pumpAndSettle();
      expect(result, 'original-request');
      expect(find.byKey(const ValueKey('workbench-body')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow large text and keyboard preserve input and reachable bottom actions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _mount(tester, scale: 1.5);
      await tester.tap(find.text('打开资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '原草稿 12.');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(find.text('原草稿 12.'), findsOneWidget);
      final actions = tester.getRect(find.byType(UtenDialogActions).first);
      expect(actions.bottom, lessThanOrEqualTo(844 - 300));
      await tester.ensureVisible(find.text('保存原资料'));
      expect(find.text('保存原资料').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'busy stage covers the complete shell and prevents repeated writes',
    (tester) async {
      final gate = Completer<void>();
      var writes = 0;
      await _mount(
        tester,
        save: () async {
          writes++;
          await gate.future;
        },
      );
      await tester.tap(find.text('打开资料'));
      await tester.pumpAndSettle();
      final save = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '保存原资料'))
          .onPressed!;
      save();
      save();
      await tester.pump();
      await tester.pump();
      expect(writes, 1);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(
        tester.getSize(find.byType(ModalBarrier).last),
        const Size(800, 600),
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _mount(
  WidgetTester tester, {
  double scale = 1,
  ValueChanged<String?>? onResult,
  Future<void> Function()? save,
}) => tester.pumpWidget(
  MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final value = await showFinanceWorkbenchPanel<String>(
              context: context,
              builder: (_) => _Workbench(save: save),
            );
            onResult?.call(value);
          },
          child: const Text('打开资料'),
        ),
      ),
    ),
  ),
);

class _Workbench extends StatefulWidget {
  const _Workbench({this.save});
  final Future<void> Function()? save;
  @override
  State<_Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<_Workbench> {
  bool _busy = false;
  final _text = TextEditingController();
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.save?.call();
      if (mounted) Navigator.pop(context, 'original-request');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: UtenDialogFrame(
      child: Material(
        key: const ValueKey('workbench-body'),
        child: Column(
          children: [
            const UtenDialogHeader(
              title: UtenDialogTitleWithHint(
                title: Text('财务来源资料'),
                info: '保留原来源和原草稿。',
              ),
            ),
            Expanded(
              child: SingleChildScrollView(child: TextField(controller: _text)),
            ),
            UtenDialogActions(
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (context) => UtenDialogFrame(
                            maxWidth: 560,
                            child: UtenDialogActions(
                              children: [
                                UtenButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('返回资料'),
                                ),
                              ],
                            ),
                          ),
                        ),
                  child: const Text('核对选项'),
                ),
                UtenButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('保存原资料'),
                ),
              ],
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在保存原资料',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    ),
  );
}
