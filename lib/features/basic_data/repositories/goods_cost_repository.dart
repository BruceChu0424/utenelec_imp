import 'dart:typed_data';
import '../../../core/network/api_exception.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../../../shared/paging/versioned_summary_read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../models/goods_cost_sheet.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/search/table_column_query.dart';

abstract interface class GoodsCostRepository {
  Future<Map<String, dynamic>> productionOutput(
    String goodsId, {
    String? executionSegmentId,
  });
  Future<GoodsCostCalculation> bootstrap(String goodsId, {String? clientId});
  Future<Map<String, dynamic>> convertCurrency(
    Map<String, dynamic> input,
    String? targetCurrencyId,
    String targetExchangeRateToLocal,
  );
  Future<Map<String, dynamic>> importPreview(
    String goodsId,
    Uint8List bytes,
    String filename,
  );
  Future<Map<String, dynamic>> importApply(Map<String, dynamic> request);
  Future<List<Map<String, dynamic>>> list(String goodsId);
  Future<PagedResult<Map<String, dynamic>>> versions(
    String goodsId, {
    int page = 1,
    int size = 50,
    TableColumnQuery columnQuery = const TableColumnQuery(),
  });
  Future<GoodsCostSheet> detail(String id);
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input);
  Future<GoodsCostSheet> save(
    String? id,
    Map<String, dynamic> input, {
    required String idempotencyKey,
    int? expectedVersion,
  });
  Future<GoodsCostSheet> confirm(String id, int version, String idempotencyKey);
  Future<GoodsCostSheet> copy(
    String id,
    int version,
    String idempotencyKey,
    String name,
  );
  Future<GoodsCostSnapshot> snapshot(
    String id,
    int version,
    String idempotencyKey,
  );
  Future<List<Map<String, dynamic>>> snapshots(String id);
  Future<GoodsCostSnapshot> snapshotDetail(String id);
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  );
  Future<Map<String, dynamic>> saveTemplate(
    Map<String, dynamic> input,
    String idempotencyKey,
  );
  Future<Map<String, dynamic>> actual(
    String goodsId,
    Map<String, dynamic> filters,
  );
}

/// Additive complete-read capability. Existing independent repositories retain
/// their public contracts; the production Dio implementation always requires
/// explicit complete-summary metadata rather than accepting a legacy prefix.
abstract interface class GoodsCostVersionedReads {
  Future<Map<String, dynamic>?> latestVersionForDefault(
    String goodsId, {
    required bool Function() isCurrent,
  });
  Future<PagedResult<Map<String, dynamic>>> completeVersions(
    String goodsId, {
    required bool Function() isCurrent,
    TableColumnQuery columnQuery = const TableColumnQuery(),
  });
  Future<List<Map<String, dynamic>>> completeTemplateSummaries(
    String goodsId,
    String? clientId, {
    required bool Function() isCurrent,
  });
  Future<Map<String, dynamic>> selectedTemplateDetail(
    String id,
    String goodsId,
    String? clientId,
  );
}

extension GoodsCostCompleteReads on GoodsCostRepository {
  /// A single latest default is a selection operation, never the contents of
  /// the comparison list. The comparison list is read completely when opened.
  Future<Map<String, dynamic>?> latestVersionForDefaultRead(
    String goodsId, {
    required bool Function() isCurrent,
  }) async {
    final repository = this;
    if (repository is GoodsCostVersionedReads) {
      return (repository as GoodsCostVersionedReads).latestVersionForDefault(
        goodsId,
        isCurrent: isCurrent,
      );
    }
    final rows = await list(goodsId);
    if (!isCurrent()) throw const UiWorkCancelled();
    return rows.firstOrNull;
  }

  Future<List<Map<String, dynamic>>> completeVersionListForRead(
    String goodsId, {
    required bool Function() isCurrent,
  }) async {
    final repository = this;
    if (repository is GoodsCostVersionedReads) {
      return (await (repository as GoodsCostVersionedReads).completeVersions(
        goodsId,
        isCurrent: isCurrent,
        columnQuery: const TableColumnQuery(
          sort: 'updatedAt',
          ascending: false,
        ),
      )).items;
    }
    // List's independent implementation contract is a complete ordered list.
    // Production Dio never uses this compatibility branch.
    final result = await list(goodsId);
    if (!isCurrent()) throw const UiWorkCancelled();
    return result;
  }

  Future<PagedResult<Map<String, dynamic>>> completeVersionsForRead(
    String goodsId, {
    required bool Function() isCurrent,
    TableColumnQuery columnQuery = const TableColumnQuery(),
  }) {
    final repository = this;
    if (repository is GoodsCostVersionedReads) {
      return (repository as GoodsCostVersionedReads).completeVersions(
        goodsId,
        isCurrent: isCurrent,
        columnQuery: columnQuery,
      );
    }
    return loadCompletePagedResult<Map<String, dynamic>>(
      isCurrent: isCurrent,
      idOf: (row) => row['id'],
      loadPage: (page, size) =>
          versions(goodsId, page: page, size: size, columnQuery: columnQuery),
    );
  }

  Future<List<Map<String, dynamic>>> completeTemplatesForRead(
    String goodsId,
    String? clientId, {
    required bool Function() isCurrent,
  }) async {
    final repository = this;
    if (repository is GoodsCostVersionedReads) {
      return (repository as GoodsCostVersionedReads).completeTemplateSummaries(
        goodsId,
        clientId,
        isCurrent: isCurrent,
      );
    }
    final result = await templates(goodsId, clientId);
    if (!isCurrent()) throw const UiWorkCancelled();
    return result;
  }

  Future<Map<String, dynamic>> selectedTemplateForRead(
    Map<String, dynamic> summary,
    String goodsId,
    String? clientId, {
    required bool Function() isCurrent,
  }) => PagedReadIntent.scopedRead(isCurrent, () async {
    if (!isCurrent()) throw const UiWorkCancelled();
    final repository = this, id = summary['id']?.toString();
    if (id == null || id.isEmpty) {
      throw ApiException('SNAPSHOT_CHANGED', '模板身份缺失，请重新读取');
    }
    final Map<String, dynamic> detail;
    if (repository is GoodsCostVersionedReads) {
      detail = await (repository as GoodsCostVersionedReads)
          .selectedTemplateDetail(id, goodsId, clientId);
    } else if (summary['input'] is Map<String, dynamic>) {
      // Existing independent full-template implementations already own this
      // selected detail. No production request falls back to all details.
      detail = summary;
    } else {
      throw ApiException(
        'INCOMPLETE_READ_PROTOCOL',
        '服务端尚未提供所选模板完整资料，请更新服务端后重试',
      );
    }
    if (!isCurrent()) throw const UiWorkCancelled();
    if (detail['id']?.toString() != id ||
        detail['input'] is! Map<String, dynamic> ||
        summary['version'] != null && summary['version'] != detail['version']) {
      throw ApiException('SNAPSHOT_CHANGED', '所选模板版本已变化，请刷新模板后重新核对');
    }
    return detail;
  });
}

class DioGoodsCostRepository
    implements GoodsCostRepository, GoodsCostVersionedReads {
  DioGoodsCostRepository(this.api);
  final ApiClient api;
  static const base = '/master/goods/cost-sheets';
  @override
  Future<Map<String, dynamic>?> latestVersionForDefault(
    String goodsId, {
    required bool Function() isCurrent,
  }) => PagedReadIntent.scopedRead(isCurrent, () async {
    if (!isCurrent()) throw const UiWorkCancelled();
    final result = await versions(
      goodsId,
      size: 1,
      columnQuery: const TableColumnQuery(sort: 'updatedAt', ascending: false),
    );
    if (!isCurrent()) throw const UiWorkCancelled();
    return result.items.firstOrNull;
  });
  @override
  Future<Map<String, dynamic>> productionOutput(
    String goodsId, {
    String? executionSegmentId,
  }) => api.get(
    '$base/production-output',
    query: {'goodsId': goodsId, 'executionSegmentId': ?executionSegmentId},
  );
  @override
  Future<GoodsCostCalculation> bootstrap(
    String goodsId, {
    String? clientId,
  }) async => GoodsCostCalculation(
    await api.post(
      '$base/bootstrap',
      query: {'goodsId': goodsId, 'clientId': ?clientId},
    ),
  );
  @override
  Future<Map<String, dynamic>> convertCurrency(
    Map<String, dynamic> input,
    String? targetCurrencyId,
    String targetExchangeRateToLocal,
  ) => api.post(
    '$base/convert-currency',
    body: {
      'input': input,
      'targetCurrencyId': targetCurrencyId,
      'targetExchangeRateToLocal': targetExchangeRateToLocal,
    },
  );
  @override
  Future<Map<String, dynamic>> importPreview(
    String goodsId,
    Uint8List bytes,
    String filename,
  ) => api.postMultipartFile(
    '$base/import-preview?goodsId=${Uri.encodeQueryComponent(goodsId)}',
    bytes,
    filename,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );
  @override
  Future<Map<String, dynamic>> importApply(Map<String, dynamic> request) =>
      api.post('$base/import-apply', body: request);
  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) async =>
      (await completeVersions(
        goodsId,
        isCurrent: () => true,
        columnQuery: const TableColumnQuery(
          sort: 'updatedAt',
          ascending: false,
        ),
      )).items;
  @override
  Future<PagedResult<Map<String, dynamic>>> versions(
    String goodsId, {
    int page = 1,
    int size = 50,
    TableColumnQuery columnQuery = const TableColumnQuery(),
  }) async {
    final json = await api.get(
      '$base/versions',
      query: {
        'goodsId': goodsId,
        'page': page,
        'size': size,
        ...tableColumnParameters(
          columnQuery.searches,
          columnQuery.sort,
          columnQuery.ascending,
        ),
        'status': ?columnQuery.searches['status'],
        'currencyId': ?columnQuery.searches['currencyName'],
      },
    );
    return PagedResult.fromJsonResponsive(json, (row) => row);
  }

  @override
  Future<PagedResult<Map<String, dynamic>>> completeVersions(
    String goodsId, {
    required bool Function() isCurrent,
    TableColumnQuery columnQuery = const TableColumnQuery(),
  }) async {
    final result = await readVersionedSummarySnapshot<Map<String, dynamic>>(
      isCurrent: isCurrent,
      batchSize: 1000,
      decode: (row) => row,
      idOf: (row) => row['id'],
      loadPage: (page, size, revision) => api.get(
        '$base/versions/summary',
        query: {
          'goodsId': goodsId,
          'page': page,
          'size': size,
          ...tableColumnParameters(
            columnQuery.searches,
            columnQuery.sort,
            columnQuery.ascending,
          ),
          'status': ?columnQuery.searches['status'],
          'currencyId': ?columnQuery.searches['currencyName'],
          'readSnapshotRevision': ?revision,
        },
      ),
    );
    return result.page;
  }

  @override
  Future<List<Map<String, dynamic>>> completeTemplateSummaries(
    String goodsId,
    String? clientId, {
    required bool Function() isCurrent,
  }) => readCompleteVersionedSummaries<Map<String, dynamic>>(
    isCurrent: isCurrent,
    batchSize: 1000,
    decode: (row) => row,
    idOf: (row) => row['id'],
    loadPage: (page, size, revision) => api.get(
      '$base/templates/summary',
      query: {
        'goodsId': goodsId,
        'clientId': ?clientId,
        'page': page,
        'size': size,
        'readSnapshotRevision': ?revision,
      },
    ),
  );

  @override
  Future<Map<String, dynamic>> selectedTemplateDetail(
    String id,
    String goodsId,
    String? clientId,
  ) => api.get(
    '$base/templates/$id',
    query: {'goodsId': goodsId, 'clientId': ?clientId},
  );

  @override
  Future<GoodsCostSheet> detail(String id) async =>
      GoodsCostSheet(await api.get('$base/$id'));
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async =>
      GoodsCostCalculation(await api.post('$base/preview', body: input));
  @override
  Future<GoodsCostSheet> save(
    String? id,
    Map<String, dynamic> input, {
    required String idempotencyKey,
    int? expectedVersion,
  }) async {
    final body = {
      'input': input,
      'idempotencyKey': idempotencyKey,
      'expectedVersion': ?expectedVersion,
    };
    return GoodsCostSheet(
      id == null
          ? await api.post(base, body: body)
          : await api.put('$base/$id', body: body),
    );
  }

  Map<String, dynamic> _command(int version, String key) => {
    'expectedVersion': version,
    'idempotencyKey': key,
  };
  @override
  Future<GoodsCostSheet> confirm(
    String id,
    int version,
    String idempotencyKey,
  ) async => GoodsCostSheet(
    await api.post(
      '$base/$id/confirm',
      body: _command(version, idempotencyKey),
    ),
  );
  @override
  Future<GoodsCostSheet> copy(
    String id,
    int version,
    String idempotencyKey,
    String name,
  ) async => GoodsCostSheet(
    await api.post(
      '$base/$id/copy',
      body: {..._command(version, idempotencyKey), 'name': name},
    ),
  );
  @override
  Future<GoodsCostSnapshot> snapshot(
    String id,
    int version,
    String idempotencyKey,
  ) async => GoodsCostSnapshot(
    await api.post(
      '$base/$id/snapshots',
      body: _command(version, idempotencyKey),
    ),
  );
  @override
  Future<List<Map<String, dynamic>>> snapshots(String id) =>
      api.getList('$base/$id/snapshots');
  @override
  Future<GoodsCostSnapshot> snapshotDetail(String id) async =>
      GoodsCostSnapshot(await api.get('$base/snapshots/$id'));
  @override
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  ) => completeTemplateSummaries(goodsId, clientId, isCurrent: () => true);
  @override
  Future<Map<String, dynamic>> saveTemplate(
    Map<String, dynamic> input,
    String idempotencyKey,
  ) => api.post(
    '$base/templates',
    body: {'input': input, 'idempotencyKey': idempotencyKey},
  );
  @override
  Future<Map<String, dynamic>> actual(
    String goodsId,
    Map<String, dynamic> filters,
  ) => api.get('$base/actual', query: {'goodsId': goodsId, ...filters});
}

final goodsCostRepositoryProvider = Provider<GoodsCostRepository>(
  (ref) => DioGoodsCostRepository(ref.watch(apiClientProvider)),
);
