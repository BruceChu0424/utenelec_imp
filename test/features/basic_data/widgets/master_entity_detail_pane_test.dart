import 'package:uten_imp/core/network/read_scope_revision.dart';
// 共享明细区(ADR-111)：批量启停/删除一次请求、失败逐条展示原因；行启停带列表行版本、
// 不先拉详情。锁住「选 100 条就是 200 次串行请求、catch 吞错只报 N 个跳过」不再回来。
// 2026-10-18 口径：批量操作走右键菜单（多选时出批量项），右下悬浮组只挂
// 「已选 N 项 + 添加X」——测试同步改为经 rowMenuBuilder 驱动批量命令。
import 'dart:async';
import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/features/basic_data/models/master_batch.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/master_batch_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_status_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// The (page, size) requests of one complete read under the shared
/// progressive plan: 50 → 50 → 100 → 200 …, each batch at its exact offset.
List<(int, int)> _progressiveBatches(int total) {
  const plan = CompleteReadBatchPlan.progressive;
  final batches = <(int, int)>[];
  var offset = 0;
  do {
    final size = plan.sizeAt(offset);
    batches.add((offset ~/ size + 1, size));
    offset += size;
  } while (offset < total);
  return batches;
}

(int, int) _request(MasterPaneQuery query) => (query.page, query.size!);

class _Row {
  const _Row(this.id, this.name, this.status, this.version);

  final String id;
  final String name;
  final String status;
  final int version;
}

class _FakeBatchRepository implements MasterBatchRepository {
  _FakeBatchRepository({this.failIds = const {}, this.confirmIds = const {}});

  final Set<String> failIds;
  final Set<String> confirmIds;
  final deleteConfirmations = <bool>[];
  final statusCalls = <(String, String, List<MasterBatchItem>)>[];
  final deleteCalls = <(String, List<MasterBatchItem>)>[];

  MasterBatchResult _result(
    List<MasterBatchItem> items, {
    bool confirmed = false,
  }) {
    final results = [
      for (final item in items)
        MasterBatchItemResult(
          id: item.id,
          label: '货品-${item.id}',
          ok:
              !failIds.contains(item.id) &&
              (!confirmIds.contains(item.id) || confirmed),
          confirmationRequired: confirmIds.contains(item.id) && !confirmed,
          reason: failIds.contains(item.id)
              ? '货品「货品-${item.id}」不能删除：1) 它还是以下货品的 BOM 组件：FG-1 成品，请先在这些货品的 BOM 里移除它'
              : confirmIds.contains(item.id) && !confirmed
              ? '还有未结案的销售订单：XD001'
              : null,
        ),
    ];
    final ok = results.where((r) => r.ok).length;
    return MasterBatchResult(
      succeeded: ok,
      failed: results.length - ok,
      results: results,
    );
  }

  @override
  Future<MasterBatchResult> changeStatus({
    required String entityPath,
    required String status,
    required List<MasterBatchItem> items,
  }) async {
    statusCalls.add((entityPath, status, items));
    return _result(items);
  }

  @override
  Future<MasterBatchResult> delete({
    required String entityPath,
    required List<MasterBatchItem> items,
    bool confirmReferencedHide = false,
  }) async {
    deleteCalls.add((entityPath, items));
    deleteConfirmations.add(confirmReferencedHide);
    return _result(items, confirmed: confirmReferencedHide);
  }
}

class _FakeStatusRepository implements MasterStatusRepository {
  final calls = <(String, String, int?)>[];

  @override
  Future<void> change({
    required String resourcePath,
    required String status,
    int? version,
  }) async {
    calls.add((resourcePath, status, version));
  }
}

final _rows = [for (var i = 0; i < 100; i++) _Row('g$i', '货品$i', '使用', i + 7)];

class _Counters {
  int detailCalls = 0;
  int listCalls = 0;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

Future<_Counters> _pump(
  WidgetTester tester,
  _FakeBatchRepository batch,
  _FakeStatusRepository status, {
  Future<PagedResult<_Row>> Function(MasterPaneQuery)? loadPage,
  Future<_Row> Function(String)? loadDetail,
  bool supportsReferencedHide = false,
  bool settle = true,
  void Function(MasterEntityPaneController<_Row, _Row> pane)? onPane,
}) async {
  final counters = _Counters();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final config = MasterEntityPaneConfig<_Row, _Row>(
    noun: '货品',
    icon: Icons.inventory_2_outlined,
    defaultCodePrefix: 'HP',
    columns: [
      MasterColumnDef<_Row>(
        key: 'name',
        label: '货品名称',
        width: 200,
        value: (r) => r.name,
      ),
    ],
    idOf: (r) => r.id,
    statusOf: (r) => r.status,
    versionOf: (r) => r.version,
    labelOf: (r) => r.name,
    toolbarLeadingActions: (pane) {
      onPane?.call(pane);
      return const [];
    },
    loadCategory: (id) async => ProductCategoryDetail(
      id: id,
      code: 'C1',
      name: '成品类',
      level: 0,
      path: '成品类',
      childCount: 0,
    ),
    loadPage: (q) async {
      counters.listCalls++;
      if (loadPage != null) return loadPage(q);
      return PagedResult(
        items: _rows,
        page: 1,
        size: 100,
        total: _rows.length,
        totalPages: 1,
      );
    },
    loadFacets: (_) async => const MasterPaneFacets(fields: {}, nullCounts: {}),
    batchEntityPath: '/master/goods',
    statusResourceOf: (id) => '/master/goods/$id',
    canCreate: false,
    canEdit: true,
    canDelete: true,
    supportsReferencedHide: supportsReferencedHide,
    canStatus: true,
    loadDetail: (id) async {
      counters.detailCalls++;
      return loadDetail == null ? _rows.first : await loadDetail(id);
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'pane-batch-test'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsStatus,
          Perm.goodsDelete,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
        masterBatchRepositoryProvider.overrideWithValue(batch),
        masterStatusRepositoryProvider.overrideWithValue(status),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MasterEntityDetailPane<_Row, _Row>(
            config: config,
            categoryId: 'cat-1',
            externalKeyword: null,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 1));
  }
  return counters;
}

MasterDataTableView<_Row> _table(WidgetTester tester) => tester
    .widget<MasterDataTableView<_Row>>(find.byType(MasterDataTableView<_Row>));

/// 勾选全部 100 行(表格的勾选回调就是页面会收到的那一个)。
Future<void> _selectAll(WidgetTester tester) async {
  _table(tester).onSelectedIdsChanged!({for (final r in _rows) r.id});
  await tester.pumpAndSettle();
}

/// 右键多选批量菜单里的指定条目（作用于整个选中集）。取首行——它必须已在
/// 选中集内，多选分支才会出批量项。
UtenMenuItem _batchMenuEntry(WidgetTester tester, String label) =>
    _table(tester).rowMenuBuilder!(_rows[0])
        .whereType<UtenMenuItem>()
        .firstWhere((e) => e.label == label);

Future<void> _statusAction(WidgetTester tester, UtenMenuItem entry) async {
  unawaited(Future<void>.sync(entry.onTap));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '确认'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'reveal uses the complete local result and only refreshes when the identity is missing',
    (tester) async {
      late MasterEntityPaneController<_Row, _Row> pane;
      final queries = <MasterPaneQuery>[];
      var count = 250;
      await _pump(
        tester,
        _FakeBatchRepository(),
        _FakeStatusRepository(),
        onPane: (value) => pane = value,
        loadPage: (query) async {
          queries.add(query);
          final size = query.size!;
          return PagedResult(
            items: [
              for (
                var index = (query.page - 1) * size;
                index < query.page * size && index < count;
                index++
              )
                _Row('p$index', '资料$index', '使用', index),
            ],
            page: query.page,
            size: size,
            total: count,
            totalPages: (count / size).ceil(),
          );
        },
      );
      expect(_table(tester).items, hasLength(250));
      final local = pane.reveal('p249');
      await tester.pumpAndSettle();
      expect(await local, isTrue);
      // The local reveal reads nothing beyond the first complete read.
      expect(queries.map(_request), _progressiveBatches(250));
      count = 251;
      final fresh = pane.reveal('p250');
      await tester.pumpAndSettle();
      expect(await fresh, isTrue);
      // A missing identity rereads the whole current query once.
      expect(queries.map(_request), [
        ..._progressiveBatches(250),
        ..._progressiveBatches(251),
      ]);
      expect(_table(tester).items, hasLength(251));
      expect(tester.takeException(), isNull);
    },
  );
  for (final stale in [false, true]) {
    testWidgets('共享主档详情读取显示等待，${stale ? '范围变化后丢弃旧详情' : '完成后进入原编辑动作'}', (
      tester,
    ) async {
      final response = Completer<_Row>();
      await _pump(
        tester,
        _FakeBatchRepository(),
        _FakeStatusRepository(),
        loadDetail: (_) => response.future,
      );
      final finder = find.byType(MasterEntityDetailPane<_Row, _Row>);
      final controller =
          tester.state(finder) as MasterEntityPaneController<_Row, _Row>;
      _Row? received;
      final pending = controller.withDetail('g0', (row) async {
        received = row;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('正在读取货品…'), findsOneWidget);
      if (stale) {
        final container = ProviderScope.containerOf(tester.element(finder));
        container.read(readScopeRevisionProvider.notifier).state++;
        await tester.pumpAndSettle();
        expect(find.text('正在读取货品…'), findsNothing);
      }
      response.complete(_rows.first);
      await tester.pumpAndSettle();
      await pending;
      expect(received, stale ? isNull : same(_rows.first));
      expect(find.text('正在读取货品…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('主档首轮完整读取250条且批次按50→50→100→200阶梯，滚动不重查', (tester) async {
    final data = [
      for (var i = 0; i < 250; i++) _Row('s$i', '整范围$i', '使用', i + 1),
    ];
    final reads = <MasterPaneQuery>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      loadPage: (query) async {
        reads.add(query);
        return _fullBatch(data, query);
      },
    );
    final table = _table(tester);
    expect(table.items, hasLength(250));
    expect(table.totalPages, 1);
    expect(table.currentPage, 1);
    // (1,50) (2,50) (2,100) (2,200): every batch at its exact offset.
    expect(reads.map(_request), _progressiveBatches(250));
    final count = reads.length;
    final viewport = find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .first;
    final position = tester.state<ScrollableState>(viewport).position;
    for (final fraction in [.8, .0, 1.0, .0]) {
      position.jumpTo(position.maxScrollExtent * fraction);
      await tester.pumpAndSettle();
    }
    expect(reads, hasLength(count));
    expect(_table(tester).items, hasLength(250));
    expect(tester.takeException(), isNull);
  });

  testWidgets('主档显式刷新重新读取整个当前查询并更新原行版本', (tester) async {
    final reads = <(int, int)>[];
    var revision = 1;
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      loadPage: (query) async {
        reads.add(_request(query));
        return _fullBatch([
          for (var i = 0; i < 130; i++)
            _Row('r$i', '修订$revision-$i', '使用', revision),
        ], query);
      },
    );
    final completeRead = _progressiveBatches(130);
    expect(reads, completeRead);
    revision = 2;
    final pane =
        tester.state(find.byType(MasterEntityDetailPane<_Row, _Row>))
            as MasterEntityPaneController<_Row, _Row>;
    final refresh = pane.reload();
    await tester.pumpAndSettle();
    await refresh;
    expect(reads, [...completeRead, ...completeRead]);
    expect(_table(tester).items, hasLength(130));
    expect(
      _table(
        tester,
      ).items.every((row) => row.version == 2 && row.name.startsWith('修订2-')),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('主档后续内部批未完成时不把首批当完整列表', (tester) async {
    final data = [
      for (var i = 0; i < 150; i++) _Row('w$i', '等待$i', '使用', i + 1),
    ];
    final completeRead = _progressiveBatches(data.length);
    final gate = Completer<PagedResult<_Row>>();
    MasterPaneQuery? gated;
    final reads = <(int, int)>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      settle: false,
      loadPage: (query) async {
        reads.add(_request(query));
        // The second internal batch stays in flight.
        if (_request(query) == completeRead[1] && gated == null) {
          gated = query;
          return gate.future;
        }
        return _fullBatch(data, query);
      },
    );
    for (var frame = 0; reads.length < 2 && frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(reads, completeRead.take(2));
    // 2026-11-07 P4.1：首批已校验即先发布 provisional 行；加载状态未清除，
    // 依赖总计的操作（导出/打印/批量/写入）仍被禁用，首批不是完整列表。
    expect(_table(tester).items, hasLength(completeRead.first.$2));
    expect(_table(tester).isLoading, isFalse);
    expect(_table(tester).loadingMore, isTrue);
    expect(_table(tester).totalPages, 1);
    gate.complete(_fullBatch(data, gated!));
    await tester.pumpAndSettle();
    expect(_table(tester).items, hasLength(150));
    expect(_table(tester).isLoading, isFalse);
    expect(_table(tester).loadingMore, isFalse);
    expect(_table(tester).totalPages, 1);
    expect(reads, completeRead);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主档完整流断流时 provisional 首批整体退休不留半份列表', (tester) async {
    final data = [
      for (var i = 0; i < 150; i++) _Row('f$i', '断流$i', '使用', i + 1),
    ];
    final completeRead = _progressiveBatches(data.length);
    final fail = Completer<PagedResult<_Row>>();
    final reads = <(int, int)>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      settle: false,
      loadPage: (query) async {
        reads.add(_request(query));
        // The second internal batch breaks the stream.
        return _request(query) == completeRead[1]
            ? fail.future
            : _fullBatch(data, query);
      },
    );
    for (var frame = 0; reads.length < 2 && frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    // Provisional first batch visible while the stream is still open...
    expect(_table(tester).items, hasLength(completeRead.first.$2));
    expect(_table(tester).loadingMore, isTrue);
    fail.completeError(ApiException('PRIMARY_UNAVAILABLE', '读取中断'));
    await tester.pumpAndSettle();
    // ...and retired as a whole when the read fails: no half list stays.
    expect(_table(tester).items, isEmpty);
    expect(_table(tester).loadingMore, isFalse);
    expect(reads, completeRead.take(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('主档离开后旧完整读取不发布也不继续请求后批', (tester) async {
    final data = [
      for (var i = 0; i < 250; i++) _Row('z$i', '已离开$i', '使用', i + 1),
    ];
    final completeRead = _progressiveBatches(data.length);
    final gate = Completer<PagedResult<_Row>>();
    MasterPaneQuery? gated;
    final reads = <(int, int)>[];
    await _pump(
      tester,
      _FakeBatchRepository(),
      _FakeStatusRepository(),
      settle: false,
      loadPage: (query) async {
        reads.add(_request(query));
        if (_request(query) == completeRead[1] && gated == null) {
          gated = query;
          return gate.future;
        }
        return _fullBatch(data, query);
      },
    );
    for (var frame = 0; reads.length < 2 && frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(reads, completeRead.take(2));
    await tester.pumpWidget(const SizedBox.shrink());
    // The exact requested batch arrives late: a retired read neither
    // publishes it nor continues with the following batches.
    gate.complete(_fullBatch(data, gated!));
    await tester.pumpAndSettle();
    expect(reads, completeRead.take(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整列表超过写入上限时不截断选择、不拆分或发送命令', (tester) async {
    final data = [
      for (var i = 0; i < 501; i++) _Row('b$i', '批量$i', '使用', i + 1),
    ];
    final batch = _FakeBatchRepository();
    await _pump(
      tester,
      batch,
      _FakeStatusRepository(),
      loadPage: (query) async => _fullBatch(data, query),
    );
    final selected = data.map((row) => row.id).toSet();
    _table(tester).onSelectedIdsChanged!(selected);
    await tester.pumpAndSettle();
    final pane =
        tester.state(find.byType(MasterEntityDetailPane<_Row, _Row>))
            as MasterEntityPaneController<_Row, _Row>;
    await pane.batchSetStatus(selected, '禁用');
    await pane.batchDelete(selected);
    await tester.pump();
    expect(batch.statusCalls, isEmpty);
    expect(batch.deleteCalls, isEmpty);
    expect(pane.selectedIds, selected);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MasterEntityDetailPane<_Row, _Row>)),
      listen: false,
    );
    expect(
      container
          .read(appNotificationProvider)
          .any(
            (notice) =>
                notice.kind == AppNotificationKind.error &&
                notice.message.contains('一次最多操作 500 条'),
          ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量禁用 100 条只发 1 次请求，带上每行版本，不逐条拉详情', (tester) async {
    final batch = _FakeBatchRepository();
    final status = _FakeStatusRepository();
    final counts = await _pump(tester, batch, status);
    await _selectAll(tester);

    await _statusAction(tester, _batchMenuEntry(tester, '批量禁用(100)'));
    await tester.pumpAndSettle();

    expect(batch.statusCalls, hasLength(1), reason: '选 100 条也只发一次批量命令');
    final (path, target, items) = batch.statusCalls.single;
    expect(path, '/master/goods');
    expect(target, '禁用');
    expect(items, hasLength(100));
    expect(items.first.version, 7, reason: '列表行版本随请求带上，服务端逐条比对');
    expect(status.calls, isEmpty, reason: '不再逐条 PATCH');
    expect(counts.detailCalls, 0, reason: '不再逐条拉详情拿版本');
    // 全部成功不弹结果框(只走顶部通知)。
    expect(find.byKey(const Key('master-batch-outcome')), findsNothing);
    // 全部成功：勾选清空。
    expect(_table(tester).selectedIds, isEmpty);
  });

  testWidgets('批量删除失败逐条展示服务端原因，失败行保留勾选', (tester) async {
    final batch = _FakeBatchRepository(failIds: {'g3', 'g4'});
    await _pump(tester, batch, _FakeStatusRepository());
    await _selectAll(tester);

    // 不等待 onTap：它会停在删除确认弹窗上，测试要在弹窗开着的当口去点「删除」
    //（与真实右键菜单交互同形，旧按钮测试的 tester.tap 也不等待按钮回调）。
    final confirmDelete = _batchMenuEntry(tester, '批量删除(100)').onTap;
    unawaited(Future<void>.sync(confirmDelete));
    await tester.pumpAndSettle();
    // 确认框(危险操作) → 删除。
    await tester.tap(find.widgetWithText(UtenButton, '删除'));
    await tester.pumpAndSettle();

    expect(batch.deleteCalls, hasLength(1));
    expect(batch.deleteCalls.single.$2, hasLength(100));
    expect(find.byKey(const Key('master-batch-outcome')), findsOneWidget);
    expect(find.text('已删除 98 个，2 个没有处理'), findsOneWidget);
    expect(find.text('货品-g3'), findsOneWidget);
    expect(find.textContaining('它还是以下货品的 BOM 组件'), findsNWidgets(2));
    await tester.tap(find.byType(UtenCloseButton));
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {'g3', 'g4'}, reason: '失败的留着方便处理后重试');
  });

  testWidgets('关联资料仍然删除只确认服务端标记行，保留原版本和其它失败', (tester) async {
    final batch = _FakeBatchRepository(failIds: {'g4'}, confirmIds: {'g3'});
    await _pump(
      tester,
      batch,
      _FakeStatusRepository(),
      supportsReferencedHide: true,
    );
    await _selectAll(tester);
    unawaited(Future<void>.sync(_batchMenuEntry(tester, '批量删除(100)').onTap));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(UtenButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('master-referenced-delete')), findsOneWidget);
    expect(find.text('去查看'), findsOneWidget);
    expect(find.textContaining('已有单据、往来账和业务记录继续保留'), findsOneWidget);
    expect(batch.deleteCalls, hasLength(1));
    await tester.tap(find.byKey(const Key('master-referenced-delete-confirm')));
    await tester.pumpAndSettle();
    expect(batch.deleteCalls, hasLength(2));
    expect(batch.deleteConfirmations, [false, true]);
    expect(batch.deleteCalls.last.$2.single.id, 'g3');
    expect(batch.deleteCalls.last.$2.single.version, 10);
    expect(find.text('已删除 99 个，1 个没有处理'), findsOneWidget);
    await tester.tap(find.byType(UtenCloseButton));
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {'g4'});
  });

  testWidgets('关联确认弹窗遇范围失效即关闭，不能继续确认删除', (tester) async {
    final batch = _FakeBatchRepository(confirmIds: {'g3'});
    await _pump(
      tester,
      batch,
      _FakeStatusRepository(),
      supportsReferencedHide: true,
    );
    await _selectAll(tester);
    unawaited(Future<void>.sync(_batchMenuEntry(tester, '批量删除(100)').onTap));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(UtenButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('master-referenced-delete')), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MasterEntityDetailPane<_Row, _Row>)),
    );
    container.read(readScopeRevisionProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('master-referenced-delete')), findsNothing);
    expect(batch.deleteCalls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final cancel in [false, true]) {
    testWidgets('500项关联资料${cancel ? '取消' : '连续点击确认'}保留完整目标且不重复提交', (
      tester,
    ) async {
      final rows = [
        for (var i = 0; i < 500; i++) _Row('g$i', '客户$i', '使用', i + 7),
      ];
      final ids = rows.map((row) => row.id).toSet();
      final batch = _FakeBatchRepository(confirmIds: ids);
      await _pump(
        tester,
        batch,
        _FakeStatusRepository(),
        supportsReferencedHide: true,
        loadPage: (_) async => PagedResult(
          items: rows,
          page: 1,
          size: 500,
          total: 500,
          totalPages: 1,
        ),
      );
      _table(tester).onSelectedIdsChanged!(ids);
      await tester.pumpAndSettle();
      final action = _batchMenuEntry(tester, '批量删除(500)').onTap;
      unawaited(Future<void>.sync(action));
      unawaited(Future<void>.sync(action));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(UtenButton, '删除'));
      await tester.pumpAndSettle();
      expect(batch.deleteCalls, hasLength(1));
      expect(batch.deleteCalls.single.$2, hasLength(500));
      final list = find.descendant(
        of: find.byKey(const Key('master-referenced-delete')),
        matching: find.byType(ListView),
      );
      expect(list, findsOneWidget);
      expect(find.text('货品-g499'), findsNothing, reason: '大列表按可视区域构建');
      await tester.drag(list, const Offset(0, -1200));
      await tester.pumpAndSettle();
      if (cancel) {
        await tester.tap(find.byType(UtenCloseButton));
      } else {
        final button = find.byKey(
          const Key('master-referenced-delete-confirm'),
        );
        final location = tester.getCenter(button);
        await tester.tapAt(location);
        await tester.tapAt(location);
      }
      await tester.pumpAndSettle();
      expect(batch.deleteCalls, hasLength(cancel ? 1 : 2));
      if (!cancel) {
        final sent = batch.deleteCalls.last.$2;
        expect(sent, hasLength(500));
        expect(sent.last.id, 'g499');
        expect(sent.last.version, 506);
        expect(_table(tester).selectedIds, isEmpty);
      } else {
        expect(_table(tester).selectedIds, ids);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('追加第二页后批量操作携带两页货品各自的版本', (tester) async {
    final batch = _FakeBatchRepository();
    await _pump(
      tester,
      batch,
      _FakeStatusRepository(),
      loadPage: (query) async => PagedResult<_Row>(
        items: [_rows[query.page - 1]],
        page: query.page,
        size: 1,
        total: 2,
        totalPages: 2,
      ),
    );
    _table(tester).onSelectedIdsChanged!({'g0'});
    await tester.pumpAndSettle();

    final displayedRows = _table(tester).rowsController!;
    await displayedRows.loadNextPage();
    await tester.pumpAndSettle();
    expect(displayedRows.items.map((row) => row.id), ['g0', 'g1']);
    expect(_table(tester).selectedIds, {'g0'});
    _table(tester).onSelectedIdsChanged!({'g0', 'g1'});
    await tester.pumpAndSettle();

    await _statusAction(tester, _batchMenuEntry(tester, '批量禁用(2)'));
    await tester.pumpAndSettle();
    expect(batch.statusCalls, hasLength(1));
    expect(
      {for (final item in batch.statusCalls.single.$3) item.id: item.version},
      {'g0': 7, 'g1': 8},
      reason: '仍显示的上一页行必须留在批量命令的版本快照中',
    );
  });

  testWidgets('行启停走单条窄命令，带列表行版本，不先拉详情', (tester) async {
    final status = _FakeStatusRepository();
    final counts = await _pump(tester, _FakeBatchRepository(), status);
    final menu = _table(tester).rowMenuBuilder!(_rows[2]);
    await _statusAction(
      tester,
      menu.whereType<UtenMenuItem>().firstWhere((e) => e.label == '禁用货品'),
    );
    await tester.pumpAndSettle();

    expect(status.calls, [('/master/goods/g2', '禁用', 9)]);
    expect(counts.detailCalls, 0);
  });

  testWidgets('单行勾选右键出单行菜单，未多选不出批量项', (tester) async {
    await _pump(tester, _FakeBatchRepository(), _FakeStatusRepository());
    _table(tester).onSelectedIdsChanged!({'g2'});
    await tester.pumpAndSettle();

    final labels = _table(tester).rowMenuBuilder!(_rows[2])
        .whereType<UtenMenuItem>()
        .map((e) => e.label)
        .toList();
    expect(labels, contains('禁用货品'));
    expect(
      labels.where((l) => l.startsWith('批量')),
      isEmpty,
      reason: '单选右键是单行菜单；批量项只在多选(>1)时出现',
    );
  });

  testWidgets('右下悬浮组只挂「已选 N 项 + 添加X」，添加随新增权限出现', (tester) async {
    // 默认 canCreate:false → 悬浮组只有已选胶囊，没有添加按钮。
    await _pump(tester, _FakeBatchRepository(), _FakeStatusRepository());
    expect(find.byKey(const ValueKey('master-add-entity')), findsNothing);
    expect(
      find.byKey(const ValueKey('master-table-clear-selection')),
      findsOneWidget,
    );
    // 标题行已删：数量进分类卡片标题，不再出现「货品 (100)」工具行文案。
    expect(find.text('货品 (100)'), findsNothing);
    expect(find.textContaining('（备注'), findsNothing);
    expect(
      find.text('成品类 (数量: 100)'),
      findsOneWidget,
      reason: '分类卡片标题 = 名称（备注）(数量: N)，与左侧列表同形',
    );
  });
}

PagedResult<_Row> _fullBatch(List<_Row> data, MasterPaneQuery query) {
  final size = query.size ?? 100;
  return PagedResult<_Row>(
    items: data.skip((query.page - 1) * size).take(size).toList(),
    page: query.page,
    size: size,
    total: data.length,
    totalPages: (data.length / size).ceil(),
  );
}
