import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_data.dart';
import 'package:uten_imp/features/report/shared/report_metadata_reuse.dart';

ReportData _report(String label) => parseReportResponse({
  'columns': [
    {'key': 'field', 'label': label, 'type': 'text'},
  ],
  'rows': [
    {'field': 'private row'},
  ],
  'facets': <String, dynamic>{},
  'total': 8,
  'totalPages': 2,
  'totals': <dynamic>[],
}, 1);

void main() {
  test('同查询回切只保留真实表头，不沿用行、筛选桶、统计', () {
    final cache = ReportMetadataReuse();
    final first = cache.begin(endpoint: '/A', query: {}, readerEpoch: 1);
    expect(cache.loadingData.columns, isEmpty);
    first.merge(_report('服务端A列'));
    cache.accept(first);
    cache.begin(endpoint: '/B', query: {}, readerEpoch: 1);
    expect(cache.loadingData.columns, isEmpty);
    cache.begin(endpoint: '/A', query: {}, readerEpoch: 1);
    expect(cache.loadingData.columns.single.label, '服务端A列');
    expect(cache.loadingData.rows, isEmpty);
    expect(cache.loadingData.facets, isEmpty);
    expect(cache.loadingData.totals, isEmpty);
    expect(cache.loadingData.total, 0);
  });

  test('查询变化、读者变化和invalidate不能继承旧表头', () {
    final cache = ReportMetadataReuse();
    final first = cache.begin(
      endpoint: '/A',
      query: {'side': 'AR'},
      readerEpoch: 1,
    )..merge(_report('客户'));
    cache.accept(first);
    cache.begin(endpoint: '/A', query: {'side': 'AP'}, readerEpoch: 1);
    expect(cache.loadingData.columns, isEmpty);
    cache.begin(endpoint: '/A', query: {'side': 'AR'}, readerEpoch: 2);
    expect(cache.loadingData.columns, isEmpty);
    cache.begin(endpoint: '/A', query: {'side': 'AR'}, readerEpoch: 1);
    expect(cache.loadingData.columns, isEmpty, reason: '读者A-B-A也不复活旧表头');
    final next = cache.begin(endpoint: '/A', query: {}, readerEpoch: 1)
      ..merge(_report('当前列'));
    cache.accept(next);
    cache.invalidate();
    expect(cache.loadingData.columns, isEmpty);
  });

  test('旧请求和未accept的响应不能发布表头缓存', () {
    final cache = ReportMetadataReuse();
    final stale = cache.begin(endpoint: '/A', query: {}, readerEpoch: 1)
      ..merge(_report('旧列'));
    cache.begin(endpoint: '/B', query: {}, readerEpoch: 1);
    cache.accept(stale);
    cache.begin(endpoint: '/A', query: {}, readerEpoch: 1);
    expect(cache.loadingData.columns, isEmpty);
  });

  test('表头缓存有界，避免多分类查询长期增长', () {
    final cache = ReportMetadataReuse();
    for (var index = 0; index < 13; index++) {
      final read = cache.begin(endpoint: '/$index', query: {}, readerEpoch: 1)
        ..merge(_report('列$index'));
      cache.accept(read);
    }
    cache.begin(endpoint: '/0', query: {}, readerEpoch: 1);
    expect(cache.loadingData.columns, isEmpty);
    cache.begin(endpoint: '/12', query: {}, readerEpoch: 1);
    expect(cache.loadingData.columns.single.label, '列12');
  });
}
