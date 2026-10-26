import 'dart:async';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';

/// All business transport is synthetic and denied at Dio's transport boundary.
class PartyReadFixtureApi extends ApiClient {
  PartyReadFixtureApi({this.ordinaryDelay = const Duration(milliseconds: 120)})
    : super(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException(
                  requestOptions: options,
                  error: 'Synthetic harness forbids business transport',
                ),
              ),
            ),
          ),
      );
  static const candidateCount = 1201;
  static const restoredId = 'party-1201';
  final requests = <Map<String, dynamic>>[];
  final clock = Stopwatch()..start();
  String actor = 'A';
  int scope = 1;
  bool delayNext = false;
  final Duration ordinaryDelay;

  void event(String action, [Map<String, dynamic> parameters = const {}]) {
    if (requests.length < 10000) {
      requests.add({
        'action': action,
        'atMs': clock.elapsedMilliseconds,
        ...parameters,
      });
    }
  }

  Future<(String, int)> _begin(
    String path,
    Map<String, dynamic>? query,
    Object? body,
  ) async {
    final captured = (actor, scope);
    final delayed = delayNext;
    delayNext = false;
    event('request-start', {
      'path': path,
      'query': {...?query},
      'body': body,
      'actor': captured.$1,
      'scope': captured.$2,
      'delayMs': delayed ? 2500 : ordinaryDelay.inMilliseconds,
    });
    await Future<void>.delayed(
      delayed ? const Duration(milliseconds: 2500) : ordinaryDelay,
    );
    event('request-return', {
      'path': path,
      'actor': captured.$1,
      'scope': captured.$2,
    });
    return captured;
  }

  Map<String, dynamic> _party(int index, bool client, String reader) => {
    'id': 'party-${index.toString().padLeft(4, '0')}',
    'code': '${client ? 'CL' : 'SU'}${index.toString().padLeft(4, '0')}',
    'name':
        '$reader-${index == 1
            ? '历史禁用往来方'
            : index == candidateCount
            ? '末页历史往来方'
            : '${client ? '客户' : '供应商'}${index.toString().padLeft(4, '0')}'}',
    'categoryId': 'leaf',
    'status': index == 1 || index == candidateCount ? '禁用' : '使用',
    'selectable': index != 1 && index != candidateCount,
  };

  List<Map<String, dynamic>> _matching(
    bool client,
    Map<String, dynamic>? query,
    Object? body,
    String reader,
  ) {
    final keyword = body is Map ? body['keyword']?.toString().trim() ?? '' : '';
    final selectable =
        (query?['selectableOnly'] ??
            (body is Map ? body['selectableOnly'] : null)) ==
        true;
    return [
          for (var index = 1; index <= candidateCount; index++)
            _party(index, client, reader),
        ]
        .where(
          (row) =>
              (!selectable || row['selectable'] == true) &&
              (keyword.isEmpty ||
                  row.values.any((value) => '$value'.contains(keyword))),
        )
        .toList();
  }

  Map<String, dynamic> _page(
    String path,
    Map<String, dynamic>? query,
    Object? body,
    (String, int) captured,
  ) {
    final matches = _matching(
      path.contains('clients'),
      query,
      body,
      captured.$1,
    );
    if (path.endsWith('/search-context')) {
      return {
        'categories': [
          if (matches.isNotEmpty)
            {'categoryId': 'leaf', 'count': matches.length},
        ],
        'totalMatches': matches.length,
        'page': 1,
        'totalPages': matches.isEmpty ? 0 : 1,
        'totalCategories': matches.isEmpty ? 0 : 1,
        'readScopeVersion': 'fixture-${captured.$2}',
      };
    }
    final page = query?['page'] as int? ?? 1,
        size = query?['size'] as int? ?? 20;
    return {
      'items': matches.skip((page - 1) * size).take(size).toList(),
      'page': page,
      'size': size,
      'total': matches.length,
      'totalPages': (matches.length / size).ceil(),
      'readScopeVersion': 'fixture-${captured.$2}',
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final captured = await _begin(path, query, null);
    if (path == '/master/clients' || path == '/master/suppliers') {
      return _page(path, query, null, captured);
    }
    if (path.contains('/reports/')) {
      final page = query?['page'] as int? ?? 1,
          size = query?['size'] as int? ?? 50;
      final total = query?['partyId'] == null ? candidateCount : 1;
      final include = query?['includeCount'] != false;
      return {
        'columns': [
          {'key': 'billNo', 'label': '单号', 'type': 'text', 'width': 180},
          {'key': 'party', 'label': '往来单位', 'type': 'text', 'width': 240},
          {'key': 'amount', 'label': '原币金额', 'type': 'money', 'width': 180},
          {'key': 'remark', 'label': '来源', 'type': 'text', 'width': 320},
        ],
        'rows': [
          for (
            var index = (page - 1) * size;
            index < total && index < page * size;
            index++
          )
            {
              'id': 'event-$index',
              'billNo': 'FIX-${index.toString().padLeft(4, '0')}',
              'party': '${captured.$1}-${query?['partyId'] ?? '全部历史往来方'}',
              'amount': '1.00000001',
              'remark': '合成原文；不连接业务库；scope=${captured.$2}',
            },
        ],
        'facets': <String, Object>{},
        'page': page,
        'total': include ? total : -1,
        'totalPages': include ? (total / size).ceil() : -1,
        'totals': query?['includeTotals'] == false
            ? <Object>[]
            : [
                {
                  'key': 'amount',
                  'label': '合成总金额',
                  'type': 'money',
                  'unitLabel': '元',
                  'groups': [
                    {'value': total == 1 ? '1.00000001' : '1201.00001201'},
                  ],
                },
              ],
        'readScopeVersion': 'fixture-${captured.$2}',
        'statisticsGeneratedAt': DateTime.now().toUtc().toIso8601String(),
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final captured = await _begin(path, query, body);
    if (path.startsWith('/master/clients/') ||
        path.startsWith('/master/suppliers/')) {
      return _page(path, query, body, captured);
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    event('synthetic-preference-write', {'path': path});
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final captured = await _begin(path, query, null);
    if (path.contains('/clients/dict') || path.contains('/suppliers/dict')) {
      throw StateError(
        'Unbounded party dictionaries are forbidden in this harness',
      );
    }
    if (path.endsWith('-categories/tree')) {
      return [
        {
          'id': 'root',
          'code': 'ROOT',
          'name': '完整历史往来方',
          'level': 0,
          'children': [
            {
              'id': 'leaf',
              'code': 'LEAF',
              'name': '测试分类',
              'level': 1,
              'children': <Object>[],
            },
          ],
        },
      ];
    }
    if (path.endsWith('/lookup')) {
      final ids = (query?['ids']?.toString() ?? '').split(',').toSet();
      return [
        for (var index = 1; index <= candidateCount; index++)
          if (ids.contains('party-${index.toString().padLeft(4, '0')}'))
            _party(index, path.contains('clients'), captured.$1),
      ];
    }
    if (path.contains('currencies')) {
      return [
        {'id': 'cny', 'code': 'CNY', 'name': '人民币', 'baseCurrency': true},
      ];
    }
    if (path.contains('reference-methods/settlement')) {
      return [
        {
          'id': 'monthly',
          'code': 'M30',
          'name': '月结',
          'legacyNameConfirmed': true,
        },
      ];
    }
    return [];
  }
}
