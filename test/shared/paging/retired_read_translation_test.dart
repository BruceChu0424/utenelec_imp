// 退休读取的公共状态区分(2026-11-10 性能根治 F 项)：
// 1) PagedReadOwnerChanged 类型化(仍 extends StateError 兼容旧合同)并纳入
//    isRetiredViewRead——不再按字符串猜；
// 2) mixin 把"非当前读的退休错误"统一翻译成 UiWorkCancelled：任何页面的
//    catch 都不可能把查询切换误读为加载失败(切仓 448ms-3s 假失败根因)；
// 3) 表格退休分支细分：新查询在途(error==null 且 loading)显示过渡态而非
//    失败文案；真退休(无替代读取)保持原失败呈现(既有钉死测试)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

class _TranslationHost extends ConsumerStatefulWidget {
  const _TranslationHost({
    super.key,
    required this.failWith,
    required this.onError,
    this.driftAfter = const Duration(hours: 1),
  });
  final Object Function() failWith;
  final ValueChanged<Object> onError;

  /// 中途把 currentQuery 换成别的值(查询漂移:切仓/换筛选)。
  final Duration driftAfter;
  @override
  ConsumerState<_TranslationHost> createState() => _TranslationHostState();
}

class _TranslationHostState extends ConsumerState<_TranslationHost>
    with ScopedPagedReadViewMixin<_TranslationHost> {
  String currentQuery = 'query-a';
  Timer? _driftTimer;

  @override
  void initState() {
    super.initState();
    _driftTimer = Timer(widget.driftAfter, () {
      if (mounted) setState(() => currentQuery = 'query-b');
    });
    _run();
  }

  @override
  void dispose() {
    _driftTimer?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      await readScopedPage<_Row>(
        1,
        query: currentQuery,
        currentQuery: () => currentQuery,
        fetchPage: (_) => throw UnimplementedError(),
        fetchComplete: () async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          throw widget.failWith();
        },
        idOf: (row) => row.id,
      );
    } catch (error) {
      widget.onError(error);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<PagedResult<String>> _load(int page, int size, {int total = 450}) async {
  final start = (page - 1) * size;
  final end = (start + size).clamp(0, total);
  return PagedResult<String>(
    items: [for (var i = start; i < end; i++) 'row-$i'],
    page: page,
    size: size,
    total: total,
    totalPages: (total + size - 1) ~/ size,
    readScopeVersion: 'scope-a',
  );
}

void main() {
  test('isRetiredViewRead 覆盖类型化 owner 变更并保持 StateError 兼容', () {
    final ownerChanged = PagedReadOwnerChanged();
    expect(ownerChanged, isA<StateError>(), reason: '既有 throwsStateError 合同不变');
    expect(isRetiredViewRead(ownerChanged), isTrue);
    expect(isRetiredViewRead(const UiWorkCancelled()), isTrue);
    expect(isRetiredViewRead(ApiException('REQUEST_STALE', '读取已取消')), isTrue);
    expect(isRetiredViewRead(ApiException('BOOM', '真失败')), isFalse);
    expect(isRetiredViewRead(StateError('其它')), isFalse);
  });

  testWidgets('非当前读的退休错误统一翻译成 UiWorkCancelled; 真失败原样上抛', (tester) async {
    final retired = <Object>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: _TranslationHost(
            key: const ValueKey('retired'),
            driftAfter: const Duration(milliseconds: 10),
            failWith: () => ApiException('REQUEST_STALE', '读取已取消'),
            onError: retired.add,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(retired, isNotEmpty);
    expect(
      retired.single,
      isA<UiWorkCancelled>(),
      reason: '页面 catch 只可能见到安静的 UiWorkCancelled,不再误报加载失败',
    );

    final genuine = <Object>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: _TranslationHost(
            key: const ValueKey('genuine'),
            failWith: () => ApiException('BOOM', '真失败'),
            onError: genuine.add,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(genuine.single, isA<ApiException>(), reason: '当前请求的真失败原样上抛,不吞不错报');
    expect((genuine.single as ApiException).code, 'BOOM');
    expect(tester.takeException(), isNull);
  });

  testWidgets('表格退休分支: 新查询在途显示过渡态, 无替代读取保持失败呈现', (tester) async {
    final published = <PagedResult<String>>[];
    final reader = ScopedPagedRead<String>(idOf: (row) => row);
    await tester.runAsync(
      () => expectLater(
        reader.read(
          1,
          scope: 'retired-switch',
          fetchPage: (page) => _load(page, 100),
          fetchPageSized: (page, size) => size == 200
              ? throw StateError('stream broke')
              : _load(page, size),
          isCurrent: () => true,
          onProgressiveBatch: published.add,
        ),
        throwsStateError,
      ),
    );
    final withdrawn = published.last.items;
    expect(readWindowBindingOf(withdrawn)!.isCurrent, isFalse);

    var refreshing = true;
    Widget app() => MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => MasterDataTableView<String>(
            items: withdrawn,
            isRefreshing: refreshing,
            columns: [
              MasterColumnDef(
                key: 'id',
                label: '编号',
                width: 300,
                value: (row) => row,
              ),
            ],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(app());
    // 刷新态存在常驻指示动画,用有界泵推进而非 pumpAndSettle。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('正在按新条件读取'), findsOneWidget, reason: '切仓/换筛选的退休过渡态不是失败');
    expect(find.text('数据加载失败'), findsNothing);
    expect(find.text('重试'), findsNothing, reason: '过渡态不需要重试入口');

    // 替代读取结束/没有替代读取:回到既有失败呈现(钉死合同不变)。
    refreshing = false;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('正在按新条件读取'), findsNothing);
    expect(find.text('数据加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
