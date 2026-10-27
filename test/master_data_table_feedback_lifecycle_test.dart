import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.refreshStatus});
  final bool refreshStatus;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final rows = [for (var index = 0; index < 40; index++) 'row-$index'];
  bool loading = false;

  void finish() => setState(() => loading = false);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            FilledButton(
              key: const Key('open-result'),
              onPressed: () {
                setState(() => loading = true);
                unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('处理结果'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭结果'),
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: const Text('打开结果'),
            ),
            Expanded(
              child: MasterDataTableView<String>(
                items: rows,
                rowKeyOf: (row) => row,
                columns: [
                  MasterColumnDef<String>(
                    key: 'name',
                    label: '名称',
                    width: 260,
                    value: (row) => row,
                  ),
                ],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                loadingMore: loading && !widget.refreshStatus,
                isRefreshing: loading && widget.refreshStatus,
                totalPages: 2,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  for (final refreshStatus in [false, true]) {
    testWidgets(
      'covered table feedback pauses animation and resumes without clearing load ($refreshStatus)',
      (tester) async {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(
          _Harness(key: key, refreshStatus: refreshStatus),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-result')));
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('处理结果'), findsOneWidget);
        expect(key.currentState!.loading, isTrue);
        final indicators = find.byWidgetPredicate(
          (widget) => widget is ProgressIndicator,
        );
        expect(indicators, findsWidgets);
        expect(
          indicators.evaluate().every(
            (element) => !TickerMode.valuesOf(element).enabled,
          ),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        await tester.tap(find.text('关闭结果'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(key.currentState!.loading, isTrue);
        expect(
          indicators.evaluate().any(
            (element) => TickerMode.valuesOf(element).enabled,
          ),
          isTrue,
        );
        key.currentState!.finish();
        await tester.pumpAndSettle();
        expect(find.byType(MasterDataTableView<String>), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
