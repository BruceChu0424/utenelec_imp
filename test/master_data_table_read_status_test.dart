import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

final _longReason = List.generate(
  80,
  (index) => '第$index项：服务器未能完成此次读取，请保留完整错误供检查。',
).join('\n');

Finder _dialogText(String text) => find.descendant(
  of: find.byType(UtenAlertDialog),
  matching: find.text(text),
);

Future<void> _touch(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture();
  await gesture.down(tester.getCenter(finder));
  await gesture.up();
  await tester.pumpAndSettle();
}

class _PageHarness extends StatefulWidget {
  const _PageHarness({super.key, required this.prepend});
  final bool prepend;

  @override
  State<_PageHarness> createState() => _PageHarnessState();
}

class _PageHarnessState extends State<_PageHarness> {
  final rows = MasterDataTableRowsController<String>();
  final requests = <int>[];
  final pending = <Completer<List<String>>>[];
  List<String> items = List.generate(12, (index) => '原记录$index');
  late int page = widget.prepend ? 2 : 1;
  bool loading = false;
  String? error;

  Future<void> load(int target) async {
    final response = Completer<List<String>>();
    requests.add(target);
    pending.add(response);
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final next = await response.future;
      if (!mounted) return;
      setState(() {
        items = next;
        page = target;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        error = _longReason;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 600,
        height: 420,
        child: MasterDataTableView<String>(
          columns: [
            MasterColumnDef<String>(
              key: 'name',
              label: '货品名称',
              width: 260,
              value: (row) => row,
            ),
          ],
          items: items,
          rowKeyOf: (row) => row,
          rowsController: rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          currentPage: page,
          totalPages: widget.prepend ? 2 : 3,
          paginationScope: 'same-query',
          onPageChange: load,
          loadingMore: loading,
          error: error,
        ),
      ),
    ),
  );
}

ScrollableState _vertical(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byType(ListView).first,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      )
      .first,
);

void main() {
  testWidgets(
    'first read failure keeps headers and reveals a long reason on touch',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 320,
              child: MasterDataTableView<String>(
                items: const [],
                columns: [
                  MasterColumnDef<String>(
                    key: 'name',
                    label: '货品名称',
                    width: 260,
                    value: (row) => row,
                  ),
                ],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                error: _longReason,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('货品名称'), findsOneWidget);
      expect(find.text('数据加载失败'), findsOneWidget);
      expect(find.text(_longReason), findsNothing);
      expect(
        find.byKey(const ValueKey('master-table-initial-read-retry')),
        findsNothing,
      );
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('master-table-initial-read-error')),
            )
            .height,
        lessThanOrEqualTo(48),
      );
      await _touch(
        tester,
        find.byKey(const ValueKey('master-table-initial-read-details')),
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == _longReason,
        ),
        findsOneWidget,
      );
      expect(_dialogText('尚未取得本次查询的数据。重试只会重新读取数据。'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.byType(UtenCloseButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('货品名称'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'refresh touch details retain editing state at double text size dark=$dark',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final error = ValueNotifier<String?>(null);
        addTearDown(error.dispose);
        final input = TextEditingController(text: '未保存的输入');
        addTearDown(input.dispose);
        var retries = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: ValueListenableBuilder<String?>(
                valueListenable: error,
                builder: (_, reason, _) => MasterDataTableView<String>(
                  items: const ['original'],
                  columns: [
                    MasterColumnDef<String>(
                      key: 'name',
                      label: '货品名称',
                      width: 300,
                      value: (row) => row,
                      cellBuilder: (_, _) => TextField(
                        key: const ValueKey('retained-editor'),
                        controller: input,
                      ),
                    ),
                  ],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  refreshError: reason,
                  onRetry: () => retries++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final editor = find.descendant(
          of: find.byKey(const ValueKey('retained-editor')),
          matching: find.byType(EditableText),
        );
        final originalState = tester.state<EditableTextState>(editor);
        error.value = _longReason;
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(editor), same(originalState));
        expect(find.text(_longReason), findsNothing);
        await _touch(
          tester,
          find.byKey(const ValueKey('master-table-refresh-read-details')),
        );
        expect(
          find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == _longReason,
          ),
          findsOneWidget,
        );
        expect(
          _dialogText('下方为上次成功读取的数据，尚未核对最新变化。重试只会重新读取数据。'),
          findsOneWidget,
        );
        await tester.tap(_dialogText('重试'));
        await tester.pumpAndSettle();
        expect(retries, 1);
        expect(input.text, '未保存的输入');
        expect(tester.state<EditableTextState>(editor), same(originalState));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final prepend in [false, true]) {
    testWidgets(
      'huge ${prepend ? 'previous' : 'next'} page failure stays compact and retries the same page',
      (tester) async {
        final key = GlobalKey<_PageHarnessState>();
        await tester.pumpWidget(_PageHarness(key: key, prepend: prepend));
        await tester.pumpAndSettle();
        final host = key.currentState!;
        final originalRows = List.of(host.rows.items);
        final request = prepend
            ? host.rows.loadPreviousPage()
            : host.rows.loadNextPage();
        await tester.pump();
        host.pending.single.completeError(StateError('read failed'));
        await request;
        await tester.pumpAndSettle();
        if (!prepend) {
          final position = _vertical(tester).position;
          position.jumpTo(position.maxScrollExtent);
          await tester.pumpAndSettle();
        }
        expect(host.rows.items, originalRows);
        final status = find.byKey(
          const ValueKey('master-table-page-read-error'),
        );
        expect(status, findsOneWidget);
        expect(tester.getSize(status).height, lessThanOrEqualTo(48));
        expect(find.text(_longReason), findsNothing);
        await _touch(
          tester,
          find.byKey(const ValueKey('master-table-page-read-details')),
        );
        expect(
          find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == _longReason,
          ),
          findsOneWidget,
        );
        expect(_dialogText('已加载的数据仍可查看。重试只会重新读取失败的页面。'), findsOneWidget);
        await tester.tap(_dialogText('重试'));
        await tester.pump();
        expect(host.requests, prepend ? [1, 1] : [2, 2]);
        host.pending.last.complete(const ['重新读取的记录']);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('master-table-page-read-error')),
          findsNothing,
        );
        expect(host.rows.items, contains('重新读取的记录'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'group touch details retry only their group and retain expanded records',
    (tester) async {
      final failed = ValueNotifier(true);
      addTearDown(failed.dispose);
      var retries = 0, otherRetries = 0, expansions = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 500,
              child: ValueListenableBuilder<bool>(
                valueListenable: failed,
                builder: (_, hasError, _) => MasterDataTableView<String>(
                  items: const ['主表记录'],
                  columns: [
                    MasterColumnDef<String>(
                      key: 'name',
                      label: '货品名称',
                      width: 260,
                      value: (row) => row,
                    ),
                  ],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  leadingGroups: [
                    MasterDataGroup<String>(
                      id: 'failed-group',
                      title: '禁用货品',
                      items: const ['保留的分组记录'],
                      initiallyExpanded: true,
                      error: hasError ? _longReason : null,
                      onExpand: () => expansions++,
                      onRetry: () {
                        retries++;
                        failed.value = false;
                      },
                    ),
                    MasterDataGroup<String>(
                      id: 'other-group',
                      title: '其他货品',
                      items: const ['其他分组记录'],
                      initiallyExpanded: true,
                      error: '另一分组的读取错误',
                      onRetry: () => otherRetries++,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('保留的分组记录'), findsOneWidget);
      expect(find.text('其他分组记录'), findsOneWidget);
      await _touch(
        tester,
        find.byKey(
          const ValueKey('master-table-group-failed-group-read-details'),
        ),
      );
      expect(_dialogText('禁用货品 · 分组加载失败'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == _longReason,
        ),
        findsOneWidget,
      );
      expect(_dialogText('此分组未能完成读取，已显示的记录仍保留。重试只会重新读取此分组。'), findsOneWidget);
      await tester.tap(_dialogText('重试'));
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(otherRetries, 0);
      expect(
        expansions,
        0,
        reason: 'Details and retry must not toggle their group.',
      );
      expect(
        find.byKey(
          const ValueKey('master-table-group-failed-group-read-error'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('master-table-group-other-group-read-error')),
        findsOneWidget,
      );
      expect(find.text('保留的分组记录'), findsOneWidget);
      expect(find.text('其他分组记录'), findsOneWidget);
      expect(find.text('主表记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
