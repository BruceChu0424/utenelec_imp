import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/models/paged_result.dart';

const productionOverLimitRefreshKey = 'production:over-limit';

String productionOverLimitStatus(String status) => switch (status) {
  'DRAFT' => '日报草稿',
  'PENDING' => '待处理',
  'HELD' => '继续待处理',
  'RETURNED' => '待核实',
  'ACCEPTED' => '已批准转公共',
  'WITHDRAWN' => '已撤回',
  _ => '状态待核对',
};

String productionOverLimitAction(String action) => switch (action) {
  'ACCEPT_PUBLIC' => '接收为公共产出',
  'HOLD' => '继续待处理',
  'RETURN_FOR_REVIEW' => '要求核实',
  _ => '处理记录',
};

class ProductionOverLimitDisposition {
  const ProductionOverLimitDisposition(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get status => data['status'] as String? ?? '';
  int get rowVersion => (data['rowVersion'] as num).toInt();
  bool get canDecide => data['canDecide'] == true;
  String? text(String key) => data[key] as String?;
  double? quantity(String key) {
    final value = data[key];
    return value is num ? value.toDouble() : double.tryParse('$value');
  }

  String? get reportId => text('reportId');
  String? get reportNo => text('reportNo');
  String? get planNo => text('planNo');
  String? get segmentCode => text('segmentCode');
  String? get goodsName => text('goodsName');
  String? get goodsCode => text('goodsCode');
  String? get colorName => text('colorName');
  String? get unitName => text('unitName');
  String? get overLimitReason => text('overLimitReason');
  String? get blockingReason => text('blockingReason');
  double? get actualBatchQty => quantity('actualBatchQty');
  double? get withinAuthorizationQty => quantity('withinAuthorizationQty');
  double? get overLimitQty => quantity('overLimitQty');
  List<Map<String, dynamic>> get decisionHistory =>
      (data['decisionHistory'] as List? ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList(growable: false);
}

class ProductionOverLimitRepository {
  ProductionOverLimitRepository(this.api);
  final ApiClient api;
  static const _base = '/production/over-limit-dispositions';

  Future<PagedResult<ProductionOverLimitDisposition>> list({
    String status = 'PENDING',
    int page = 1,
    int size = 20,
  }) async => PagedResult.fromJson(
    await api.get(_base, query: {'status': status, 'page': page, 'size': size}),
    ProductionOverLimitDisposition.new,
  );

  Future<ProductionOverLimitDisposition> detail(String id) async =>
      ProductionOverLimitDisposition(await api.get('$_base/$id'));

  Future<ProductionOverLimitDisposition> decide(
    ProductionOverLimitDisposition source, {
    required String action,
    required String reason,
  }) async {
    final normalized = reason.trim();
    return ProductionOverLimitDisposition(
      await api.post(
        '$_base/${source.id}/decisions',
        body: {
          'action': action,
          'reason': normalized,
          'expectedVersion': source.rowVersion,
          'idempotencyKey': businessIdempotencyKey(
            'production-over-limit-decision',
            '${source.id}|${source.rowVersion}|$action|$normalized',
          ),
        },
      ),
    );
  }
}

final productionOverLimitRepositoryProvider =
    Provider<ProductionOverLimitRepository>(
      (ref) => ProductionOverLimitRepository(ref.watch(apiClientProvider)),
    );
