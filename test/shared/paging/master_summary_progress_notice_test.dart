import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/master_summary_read.dart';
import 'package:uten_imp/shared/paging/complete_read_progress.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

/// 决定性链路实证：货品资料等 flat 主档页的真实生产读取链
/// （MasterEntityDetailPane → ScopedPagedRead(fetchComplete) →
/// DioXxxRepository.completeList → readCompleteMasterSummary(NDJSON 流) →
/// readVersionedSummarySnapshot → loadCompletePagedResult）必须产生顶部
/// 加载进度事件（2026-11-09 用户实测「货品资料没弹进度卡」排查用）。
const _total = 601;

class _Api extends ApiClient {
  _Api() : super(Dio());

  @override
  Future<T> postSummaryStream<T>(
    String path, {
    required Object body,
    required Future<T> Function(Stream<Map<String, dynamic>>) consume,
  }) async {
    const plan = CompleteReadBatchPlan.progressive;
    Stream<Map<String, dynamic>> frames() async* {
      var offset = 0;
      do {
        final frameSize = plan.sizeAt(offset);
        yield {'type': 'page', 'value': _page(offset, frameSize)};
        offset += frameSize;
      } while (offset < _total);
      yield {
        'type': 'complete',
        'total': _total,
        'readScopeVersion': 'a' * 64,
        'readSnapshotRevision': 'b' * 64,
        'readDataVersion': 'c' * 64,
      };
    }

    return await consume(frames());
  }

  Map<String, dynamic> _page(int offset, int size) => <String, dynamic>{
    'items': <Map<String, dynamic>>[
      for (var i = offset; i < offset + size && i < _total; i++)
        {'id': 'record-$i'},
    ],
    'page': offset ~/ size + 1,
    'size': size,
    'total': _total,
    'totalPages': (_total + size - 1) ~/ size,
    'readScopeVersion': 'a' * 64,
    'readSnapshotRevision': 'b' * 64,
    'readDataVersion': 'c' * 64,
  };
}

void main() {
  test('goods-style summary stream read reports progress through the '
      'production chain', () async {
    final events = <CompleteReadProgressEvent>[];
    CompleteReadProgressReporter.addListener(events.add);
    final reader = ScopedPagedRead<Map<String, dynamic>>(
      idOf: (row) => row['id'] as String,
    );
    // 与 MasterEntityDetailPane 相同的调用形态：fetchComplete + onProgressiveBatch。
    final result = await reader.read(
      1,
      scope: 'goods-query',
      fetchPage: (page) => throw StateError('unused'),
      fetchComplete: () => readCompleteMasterSummary<Map<String, dynamic>>(
        _Api(),
        path: '/master/goods/summaries',
        filter: const {},
        decode: (row) => row,
        idOf: (row) => row['id'] as String,
      ),
      isCurrent: () => true,
      onProgressiveBatch: (_) {},
    );
    CompleteReadProgressReporter.removeListener(events.add);

    expect(result.items, hasLength(_total));
    expect(
      events.first.phase,
      CompleteReadProgressPhase.started,
      reason: '读取开始即上报（延迟 600ms 只是卡片展示策略，事件本身立即有）',
    );
    final batches = events
        .where((e) => e.phase == CompleteReadProgressPhase.batch)
        .toList();
    expect(batches, isNotEmpty, reason: '每个校验通过的批次都要上报累计行数');
    expect(batches.first.loaded, 50, reason: '首批 50 行（阶梯 50→50→100→200）');
    expect(batches.first.total, _total, reason: '首批即带回服务端精确总量');
    expect(
      events.last.phase,
      CompleteReadProgressPhase.succeeded,
      reason: '完整结果成功返回才 succeeded',
    );
    expect(
      batches.every((e) => e.total == _total),
      isTrue,
      reason: '分子分母同口径：累计已验证行数 ÷ 同一查询的服务端 total',
    );
  });
}
