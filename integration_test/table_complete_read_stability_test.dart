// Real-window acceptance of the synthetic production reader/table surface.
// Run with: flutter test integration_test/table_complete_read_stability_test.dart
//   -d windows --no-pub --dart-define=UTEN_LOCAL_TEST=true
//   --dart-define=API_BASE_URL=http://127.0.0.1:9/api
// This covers Flutter text-input/composition messages and pointer/key dispatch,
// not a Windows IME candidate window, financial calculations, or persisted drafts.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/core/theme/uten_scrollbar_style.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

import '../test/support/uten_test_actions.dart';
import '../tool/table_complete_read_harness.dart' as fixture;

final _table = find.byKey(const Key('table-stress-table'));
final _query = find.byKey(const Key('table-stress-query'));
final _draft = find.byKey(const Key('table-stress-draft'));
final _status = find.byKey(const Key('table-stress-status'));

MasterDataTableView<fixture.TableStressRow> _view(WidgetTester tester) =>
    tester.widget<MasterDataTableView<fixture.TableStressRow>>(_table);

Map<String, Object?> _metrics(WidgetTester tester) {
  final builder = find.ancestor(
    of: _status,
    matching: find.byWidgetPredicate(
      (widget) => widget is ValueListenableBuilder<Map<String, Object?>>,
    ),
  );
  return tester
      .widget<ValueListenableBuilder<Map<String, Object?>>>(builder)
      .valueListenable
      .value;
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready,
  String stage, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    expect(tester.takeException(), isNull, reason: stage);
    if (clock.elapsed > timeout) {
      fail(
        '$stage timed out; status: ${_status.evaluate().isEmpty ? "absent" : tester.widget<SelectableText>(_status).data}',
      );
    }
    await tester.pump(const Duration(milliseconds: 40));
  }
  expect(tester.takeException(), isNull, reason: stage);
}

Future<void> _enterQuery(WidgetTester tester, String query) async {
  // A done action unfocuses this single-line field. The integration binding's
  // focusedEditable setter can retain the same EditableTextState, so perform
  // the user's new pointer focus before reusing its text-input connection.
  await tester.tap(_query.hitTestable());
  await tester.pump();
  await tester.enterText(_query, query);
  await tester.pump();
  expect(tester.widget<TextField>(_query).controller!.text, query);
  // The native engine translates Enter to TextInputAction.done. Flutter's
  // EditableText testing contract explicitly says sendKeyEvent(enter) alone
  // does not perform that platform translation, so use its public input channel.
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  expect(
    _view(tester).paginationScope,
    query,
    reason: 'The native Enter action must execute the visible query control',
  );
}

Future<void> _verifyComplete(WidgetTester tester, int total) async {
  await _wait(tester, () {
    final table = _view(tester);
    return table.items.length == total &&
        table.rowsController!.items.length == total &&
        !table.isLoading &&
        _metrics(tester)['active'] == 0;
  }, 'complete authorized local table');
  final table = _view(tester);
  final generation = table.items.first.generation;
  final controllerRows = table.rowsController!.items;
  for (var index = 0; index < total; index++) {
    final source = table.items[index];
    final visibleSource = controllerRows[index];
    if (source.index != index ||
        source.generation != generation ||
        visibleSource.index != index ||
        visibleSource.generation != generation) {
      fail('Incomplete, duplicate, reordered or stale synthetic row at $index');
    }
    if (index % 4096 == 0) await tester.pump();
  }
  expect(_metrics(tester)['errors'], 0);
  expect(tester.takeException(), isNull);
}

/// Drag the same painted scrollbar thumb a desktop user drags; the controller
/// is observed for geometry only, never used to invoke jumpTo in this test.
Future<void> _dragScrollbar(WidgetTester tester, double fraction) async {
  final controller = utenTestTableBodyController(tester, _table);
  final barFinder = find.descendant(
    of: _table,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is UtenContentScrollbar &&
          identical(widget.controller, controller) &&
          widget.visible,
    ),
  );
  expect(barFinder, findsOneWidget);
  final bar = tester.widget<UtenContentScrollbar>(barFinder);
  expect(
    bar.windowSizedChrome,
    isFalse,
    reason: 'The fixture owns its unscaled local rail',
  );
  final rect = tester.getRect(barFinder);
  final position = controller.position;
  final track = rect.height - bar.bottomInset.clamp(0, rect.height);
  final arrow = math.min(UtenScrollbarStyle.arrowExtent, track / 3);
  final thumbTrack = track - 2 * arrow;
  final inset = bar.bottomInset.clamp(0, position.viewportDimension);
  final range = position.maxScrollExtent - position.minScrollExtent;
  final extent = (range + position.viewportDimension - inset).clamp(
    1,
    double.infinity,
  );
  final ratio = ((position.viewportDimension - inset) / extent).clamp(.05, 1.0);
  final thumb = (thumbTrack * ratio).clamp(
    math.min(UtenScrollbarStyle.minimumThumbLength, thumbTrack * .8),
    thumbTrack,
  );
  final current = ((position.pixels - position.minScrollExtent) / range).clamp(
    0.0,
    1.0,
  );
  final start = Offset(
    rect.center.dx,
    rect.top + arrow + (thumbTrack - thumb) * current + thumb / 2,
  );
  final end = Offset(
    rect.center.dx,
    rect.top + arrow + (thumbTrack - thumb) * fraction + thumb / 2,
  );
  final pointer = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await pointer.moveBy(Offset(0, end.dy > start.dy ? 20 : -20));
  await tester.pump();
  await pointer.moveTo(end);
  await tester.pump();
  await pointer.up();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native complete table survives real window input, cancellation and scrolling',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      fixture.main();
      await tester.pump();
      addTearDown(() async {
        // Dispose the harness's periodic observation timer and pending read owner.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));
      });
      await _wait(
        tester,
        () =>
            _status.evaluate().isNotEmpty &&
            _metrics(tester)['phase'] == 'PASS',
        'initial synthetic scenario',
      );
      const total = 35000;
      expect(
        _metrics(tester)['total'],
        total,
        reason: 'Native acceptance must use the requested full 35k fixture',
      );
      await _verifyComplete(tester, total);

      const input = '保留中文旁路输入：取消后继续 0001.0000';
      await tester.tap(_draft);
      await tester.showKeyboard(_draft);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '保留中文zhong',
          selection: TextSelection.collapsed(offset: 9),
          composing: TextRange(start: 4, end: 9),
        ),
      );
      await tester.pump();
      await tester.enterText(_draft, input);
      expect(tester.widget<TextField>(_draft).controller!.text, input);

      for (var query = 0; query < 20; query++) {
        await _enterQuery(tester, '桌面快速查询 $query');
        if (query % 4 == 3) {
          await tester.tap(find.text('中断读取').hitTestable());
          await tester.pump();
          expect(_view(tester).items, isEmpty);
        }
        expect(tester.widget<TextField>(_draft).controller!.text, input);
        expect(tester.takeException(), isNull, reason: 'rapid query $query');
      }
      await _wait(
        tester,
        () => _metrics(tester)['active'] == 0,
        'late cancelled replies drain',
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        _view(tester).items,
        isEmpty,
        reason: 'Late replies cannot republish a cancelled prefix',
      );
      expect(_view(tester).rowsController!.items, isEmpty);
      expect(_metrics(tester)['cancelled'], greaterThan(0));
      await _enterQuery(tester, '桌面最终恢复查询');
      await _verifyComplete(tester, total);
      expect(tester.widget<TextField>(_draft).controller!.text, input);

      final rowCheckbox = find
          .descendant(
            of: _table,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Checkbox &&
                  widget.key != const Key('master-data-table-select-all') &&
                  widget.onChanged != null,
            ),
          )
          .hitTestable()
          .first;
      await tester.tap(rowCheckbox);
      await tester.pump();
      final selected = Set<String>.of(_view(tester).selectedIds);
      expect(selected, hasLength(1));

      await tester.tap(find.textContaining('表头设置').hitTestable().first);
      await tester.pump(const Duration(milliseconds: 200));
      final chooser = find.byKey(const ValueKey('uten-column-chooser-scroll'));
      final option = find.descendant(of: chooser, matching: find.text('资料 6'));
      await tester.scrollUntilVisible(
        option,
        120,
        scrollable: find
            .descendant(of: chooser, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(option);
      await tester.pump();
      expect(_view(tester).selectedIds, selected);
      await tester.tap(option);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _wait(
        tester,
        () => chooser.evaluate().isEmpty,
        'close column chooser',
      );
      expect(_view(tester).selectedIds, selected);

      final requests = _metrics(tester)['syntheticBatchCalls'];
      for (var round = 0; round < 3; round++) {
        final tail = find.text('合成货品 034999');
        for (
          var attempt = 0;
          attempt < 3 && tail.hitTestable().evaluate().isEmpty;
          attempt++
        ) {
          await _dragScrollbar(tester, 1);
        }
        await _wait(
          tester,
          () => tail.hitTestable().evaluate().isNotEmpty,
          'last row visible after scrollbar drag',
          timeout: const Duration(seconds: 15),
        );
        expect(_view(tester).selectedIds, selected);
        await _dragScrollbar(tester, 0);
        await _wait(
          tester,
          () => find.text('合成货品 000000').hitTestable().evaluate().isNotEmpty,
          'first row visible after return drag',
          timeout: const Duration(seconds: 15),
        );
      }
      expect(
        _metrics(tester)['syntheticBatchCalls'],
        requests,
        reason: 'Scrolling the complete result must not fetch more data',
      );
      await _verifyComplete(tester, total);
      expect(_view(tester).selectedIds, selected);
      expect(tester.widget<TextField>(_draft).controller!.text, input);
      expect(tester.takeException(), isNull);

      final receipt = <String, Object?>{
        'syntheticOnly': true,
        'surface': 'native integration window',
        'rows': total,
        'rapidEnterQueries': 20,
        'cancelActions': 5,
        'scrollRoundTrips': 3,
        'selectedAfterScroll': selected.length,
        'siblingInputRetained': true,
        'inputScope':
            'Flutter text-input/composing channel, not OS IME candidate UI',
        'businessScope':
            'synthetic readonly DTOs, no financial calculation or persisted draft claim',
        'metrics': Map<String, Object?>.of(_metrics(tester)),
      };
      binding.reportData = {'tableCompleteRead': receipt};
      debugPrint('TABLE_NATIVE_ACCEPTANCE ${jsonEncode(receipt)}');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
