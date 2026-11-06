import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/business_columns/business_columns_repository.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

void main() {
  for (final platform in [false, true]) {
    final kind = platform ? 'platform' : 'business';
    test(
      '$kind catalog reads every1001 result with independent bounded batches and the original Chinese query',
      () async {
        final api = _Api();
        final rows = await _read(api, platform);
        expect(rows, hasLength(1001));
        expect(rows.first, 'definition-0');
        expect(rows.last, 'definition-1000');
        expect(rows.toSet(), hasLength(1001));
        expect(api.requests.map((r) => r.$2['page']), [1, 2]);
        expect(
          api.requests.every(
            (r) => r.$2['q'] == '正常中文' && r.$2['size'] == 1000,
          ),
          isTrue,
        );
        expect(api.requests.last.$2['readSnapshotRevision'], 'a' * 64);
        expect(
          api.requests.first.$2.containsKey('readSnapshotRevision'),
          isFalse,
        );
        expect(api.legacyReads, 0);
      },
    );
    test(
      '$kind failed or denied tail never returns a selectable prefix',
      () async {
        for (final status in [503, 403]) {
          final api = _Api()..tailStatus = status;
          await expectLater(
            _read(api, platform),
            throwsA(
              isA<ApiException>().having(
                (e) => e.httpStatus,
                'httpStatus',
                status,
              ),
            ),
          );
          expect(api.requests.map((r) => r.$2['page']), [1, 2]);
        }
      },
    );
    test(
      '$kind same-count revision replacement is rejected before publication',
      () async {
        final api = _Api()..changed = true;
        await expectLater(
          _read(api, platform),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'SNAPSHOT_CHANGED',
            ),
          ),
        );
        expect(api.requests.map((r) => r.$2['page']), [1, 2]);
      },
    );
    test(
      '$kind inherited query owner retirement starts no tail batch',
      () async {
        var current = true;
        final api = _Api()..afterFirst = (() => current = false);
        await expectLater(
          PagedReadIntent.scopedRead(() => current, () => _read(api, platform)),
          throwsA(isA<UiWorkCancelled>()),
        );
        expect(api.requests.map((r) => r.$2['page']), [1]);
      },
    );
  }
  test(
    'bounded saved definition-ID restoration retains its exact original endpoint and available-only query',
    () async {
      final api = _Api();
      final repo = PlatformTableRepository(api);
      final values = await repo.search(
        'resource',
        'ignored',
        ids: ['not-a-uuid'],
      );
      expect(values, isEmpty);
      expect(api.requests, isEmpty);
      expect(api.legacyReads, 0);
      const id = '11111111-1111-4111-8111-111111111111';
      final rows = await repo.search('resource', 'ignored', ids: [id, id]);
      expect(rows.single.id, id);
      expect(api.legacyReads, 1);
      expect(api.lastLegacyPath, '/platform-columns/resource/definitions');
      expect(api.lastLegacyQuery, {'ids': id, 'availableOnly': true});
      expect(api.requests, isEmpty);
    },
  );
}

Future<List<String>> _read(_Api api, bool platform) async => platform
    ? (await PlatformTableRepository(
        api,
      ).search('resource', '正常中文')).map((row) => row.id).toList()
    : (await BusinessColumnsRepository(
        api,
      ).search('sales_order', '正常中文')).map((row) => row.id).toList();

class _Api extends ApiClient {
  _Api()
    : super(Dio(BaseOptions(baseUrl: 'https://catalog.fixture.invalid/api')));
  final requests = <(String, Map<String, dynamic>)>[];
  int? tailStatus;
  bool changed = false;
  void Function()? afterFirst;
  int legacyReads = 0;
  String? lastLegacyPath;
  Map<String, dynamic>? lastLegacyQuery;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final q = Map<String, dynamic>.of(query!);
    requests.add((path, q));
    if (path != '/business-columns/summaries' &&
        path != '/platform-columns/resource/definitions/summaries') {
      throw StateError('Unexpected catalog path');
    }
    final page = q['page'] as int,
        size = q['size'] as int,
        start = (page - 1) * size;
    if (page == 2 && tailStatus != null) {
      throw ApiException(
        tailStatus == 403 ? 'FORBIDDEN' : 'INTERNAL',
        '目录尾批失败',
        httpStatus: tailStatus,
      );
    }
    final value = <String, dynamic>{
      'items': [
        for (var i = start; i < start + size && i < 1001; i++)
          {
            'id': 'definition-$i',
            'scope': path.startsWith('/platform') ? 'resource' : 'sales_order',
            'name': '正常中文$i',
            'type': 'TEXT',
            'operation': 'NONE',
          },
      ],
      'page': page,
      'size': size,
      'total': 1001,
      'totalPages': 2,
      'scope': 'all',
      'readScopeVersion': 'catalog-scope',
      'readSnapshotRevision': (changed && page == 2 ? 'b' : 'a') * 64,
      'readDataVersion': (changed && page == 2 ? 'd' : 'c') * 64,
    };
    if (page == 1) afterFirst?.call();
    return value;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    legacyReads++;
    lastLegacyPath = path;
    lastLegacyQuery = Map.of(query!);
    return [
      {'id': query['ids'], 'scope': 'resource', 'name': '原保存列', 'type': 'TEXT'},
    ];
  }
}
