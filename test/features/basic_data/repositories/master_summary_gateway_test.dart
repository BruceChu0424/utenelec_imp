import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/features/basic_data/models/master_search_context.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_summary_read.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/paging/complete_summary_stream.dart'
    show kProgressiveSummaryStreamSize;

const _total = 601;

/// The server frames one complete-summary stream with the plan its request
/// size selects: 100 keeps fixed frames, [kProgressiveSummaryStreamSize] the
/// 50 → 50 → 100 → 200 … ladder. Each frame is the exact page at its offset.
List<({int offset, int size})> _summaryFrames(int requestSize) {
  final plan = requestSize == kProgressiveSummaryStreamSize
      ? CompleteReadBatchPlan.progressive
      : const CompleteReadBatchPlan.fixed(100);
  final frames = <({int offset, int size})>[];
  var offset = 0;
  do {
    final size = plan.sizeAt(offset);
    frames.add((offset: offset, size: size));
    offset += size;
  } while (offset < _total);
  return frames;
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final calls =
      <({String path, Map<String, dynamic> body, String? revision})>[];
  int active = 0, peak = 0;
  int internalPages = 0;
  @override
  Future<T> postSummaryStream<T>(
    String path, {
    required Object body,
    required Future<T> Function(Stream<Map<String, dynamic>>) consume,
  }) async {
    final json = Map<String, dynamic>.from(body as Map);
    final size = json['size'] as int;
    calls.add((path: path, body: json, revision: null));
    active++;
    if (active > peak) {
      peak = active;
    }
    Stream<Map<String, dynamic>> frames() async* {
      for (final frame in _summaryFrames(size)) {
        internalPages++;
        yield {'type': 'page', 'value': summaryPage(frame.offset, frame.size)};
      }
      yield {
        'type': 'complete',
        'total': _total,
        'readScopeVersion': 'a' * 64,
        'readSnapshotRevision': 'b' * 64,
        'readDataVersion': 'c' * 64,
      };
    }

    try {
      return await consume(frames());
    } finally {
      active--;
    }
  }

  Map<String, dynamic> summaryPage(int offset, int size) => <String, dynamic>{
    'items': <Map<String, dynamic>>[
      for (var i = offset; i < offset + size && i < _total; i++)
        <String, dynamic>{
          'id': 'record-$i',
          'code': 'CODE-$i',
          'name': '中文原文$i',
          'categoryId': 'category-A',
          'status': '使用',
          'mobile': 'only-original-projection',
          'writable': false,
          'stockQtyDisplayText': '90071992547409.1234567890123456789',
        },
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

Future<void> _check<T>(
  _Api api,
  Future<PagedResult<T>> pending,
  String path,
  String Function(T) idOf,
) async {
  final result = await pending;
  expect(result.items, hasLength(_total));
  expect(idOf(result.items.last), 'record-600');
  expect(api.calls, hasLength(1));
  // One HTTP request; the server streams the progressive ladder internally.
  expect(
    api.internalPages,
    _summaryFrames(kProgressiveSummaryStreamSize).length,
  );
  expect(
    api.calls.every(
      (c) =>
          c.path == path &&
          c.body['page'] == 1 &&
          c.body['size'] == kProgressiveSummaryStreamSize,
    ),
    isTrue,
  );
  expect(api.calls.first.revision, isNull);
  expect(api.peak, 1);
}

void main() {
  for (final reference in [false, true]) {
    test(
      'client complete source=$reference keeps category/contact/selection/legacy flags in body',
      () async {
        final api = _Api(),
            base = reference
                ? '/business-references/clients'
                : '/master/clients';
        final repository = DioClientRepository(
          api,
          queryBasePath: base,
          selectionFlagsInBody: reference,
        );
        await _check(
          api,
          repository.completeList(
            'category-A',
            keyword: ' 原手机号 ',
            filters: {'mobile': '137原文', 'search.name': '精确中文'},
            selectableOnly: true,
            excludeLegacyFinanceStub: false,
          ),
          '$base/summaries',
          (row) => row.id,
        );
        final filter = api.calls.first.body['filter'] as Map;
        expect(filter['categoryId'], 'category-A');
        expect(filter['keyword'], '原手机号');
        expect(filter['mobile'], '137原文');
        expect(filter['columnSearch'], {'name': '精确中文'});
        expect(filter['selectableOnly'], isTrue);
        expect(filter['excludeLegacyFinanceStub'], isFalse);
      },
    );
    test(
      'supplier complete source=$reference keeps original source and selectableOnly',
      () async {
        final api = _Api(),
            base = reference
                ? '/business-references/suppliers'
                : '/master/suppliers';
        final repository = DioSupplierRepository(
          api,
          queryBasePath: base,
          selectionFlagsInBody: reference,
        );
        await _check(
          api,
          repository.completeList(
            'category-A',
            keyword: '供应商原词',
            filters: {'bankAccount': '原银行值'},
            selectableOnly: true,
          ),
          '$base/summaries',
          (row) => row.id,
        );
        final filter = api.calls.first.body['filter'] as Map;
        expect(filter['selectableOnly'], isTrue);
        expect(filter['bankAccount'], '原银行值');
      },
    );
    test(
      'goods complete source=$reference keeps category roots, refs and exact scope flags',
      () async {
        final api = _Api(),
            base = reference ? '/business-references/goods' : '/master/goods';
        final repository = DioGoodsRepository(api, queryBasePath: base);
        await _check(
          api,
          repository.completeList(
            'category-A',
            keyword: '原货品',
            categoryRootIds: {'root-B', 'root-A'},
            filters: {'colorLegacyId': 'uuid:color'},
            excludeDisabled: true,
            excludeStub: true,
            includeRelated: true,
          ),
          '$base/summaries',
          (row) => row.id,
        );
        final filter = api.calls.first.body['filter'] as Map;
        expect(filter['categoryRootIds'], ['root-A', 'root-B']);
        expect(filter['colorRef'], 'uuid:color');
        expect(filter['excludeDisabled'], isTrue);
        expect(filter['excludeStub'], isTrue);
        expect(filter['includeRelated'], isTrue);
      },
    );
  }
  test(
    'mould master complete keeps original filters and typed full tail',
    () async {
      final api = _Api();
      await _check(
        api,
        DioMouldRepository(api).completeList(
          'category-A',
          keyword: '模具原词',
          filters: {'search.code': 'ABC', 'location': '__null__'},
          sort: 'code',
          order: 'desc',
        ),
        '/master/moulds/summaries',
        (row) => row.id,
      );
      final filter = api.calls.first.body['filter'] as Map;
      expect(filter['columnSearch'], {'code': 'ABC'});
      expect(filter['nullFields'], ['location']);
      expect(api.calls.first.body['order'], 'desc');
    },
  );
  test(
    'exact summary POST reads never become business writes or authorize neighbors',
    () {
      for (final base in [
        '/master/clients',
        '/master/suppliers',
        '/master/moulds',
        '/master/goods',
        '/master/colors',
        '/master/units',
        '/master/currencies',
        '/master/accounts',
        '/master/reference-methods/settlement-admin',
        '/business-references/clients',
        '/business-references/suppliers',
        '/business-references/goods',
      ]) {
        for (final prefix in ['', '/api']) {
          expect(
            isBusinessWrite(
              RequestOptions(method: 'POST', path: '$prefix$base/summaries'),
            ),
            isFalse,
          );
          expect(
            isBusinessWrite(
              RequestOptions(method: 'PUT', path: '$prefix$base/summaries'),
            ),
            isTrue,
          );
          expect(
            isBusinessWrite(
              RequestOptions(
                method: 'POST',
                path: '$prefix$base/summaries/apply',
              ),
            ),
            isTrue,
          );
        }
      }
    },
  );
  test(
    'compact category metadata collects151 categories instead of10001 business rows',
    () async {
      final requests = <int>[];
      final ids = await readCompleteMasterSearchCategories(
        isCurrent: () => true,
        loadPage: (page) async {
          requests.add(page);
          return MasterSearchContext(
            categoryIds: [
              for (var i = (page - 1) * 100; i < page * 100 && i < 151; i++)
                'category-$i',
            ],
            totalMatches: 10001,
            page: page,
            totalPages: 2,
            totalCategories: 151,
            readScopeVersion: 'a' * 64,
          );
        },
      );
      expect(ids, hasLength(151));
      expect(ids.last, 'category-150');
      expect(requests, [1, 2]);
    },
  );
}
