// 不良品专门通道(ADR-146)：「转不良品仓」「不良复判转回」一次建单并过账。
// 能不能办由服务端按独立权限算好(options)，页面不在本地拼权限。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// 两种通道的服务端代码。
abstract final class DefectiveMoveKind {
  static const toDefective = 'TO_DEFECTIVE';
  static const release = 'DEFECT_RELEASE';
}

/// 一次过账的结果: 生成的调拨单号 + 给办理人的提醒(转走后已经没有实物的预留, 服务端算好的大白话)。
class DefectiveMoveResult {
  const DefectiveMoveResult({required this.billNo, this.warnings = const []});

  final String billNo;
  final List<String> warnings;

  factory DefectiveMoveResult.fromJson(Map<String, dynamic> json) {
    final document = json['document'];
    return DefectiveMoveResult(
      billNo: document is Map ? '${document['billNo'] ?? ''}' : '',
      warnings: [
        for (final warning in (json['warnings'] as List? ?? const []))
          if (warning is String && warning.trim().isNotEmpty) warning.trim(),
      ],
    );
  }
}

class DefectiveMoveRepository {
  DefectiveMoveRepository(this.api);
  final ApiClient api;

  /// 当前用户能办理的通道(空 = 都不能办)。
  Future<Set<String>> options() async {
    final json = await api.get(ApiEndpoints.stockDefectiveMoveOptions);
    return {
      for (final kind in (json['kinds'] as List? ?? const []))
        if (kind is String) kind,
    };
  }

  /// 一次建单并过账；同一 [requestKey] 同一内容重试回放原单, 换了内容服务端回 409。
  Future<DefectiveMoveResult> create({
    required String kind,
    required String fromWarehouseId,
    required String toWarehouseId,
    required String reason,
    required String requestKey,
    required String goodsId,
    String? colorId,
    String? unitId,
    required double qty,
  }) async {
    final json = await api.post(
      ApiEndpoints.stockDefectiveMoves,
      body: {
        'kind': kind,
        'fromWarehouseId': fromWarehouseId,
        'toWarehouseId': toWarehouseId,
        'reason': reason,
        'requestKey': requestKey,
        'items': [
          {
            'goodsId': goodsId,
            'colorId': ?colorId,
            'unitId': ?unitId,
            'unitRate': 1,
            'qty': qty,
          },
        ],
      },
    );
    return DefectiveMoveResult.fromJson(json);
  }
}

final defectiveMoveRepositoryProvider = Provider<DefectiveMoveRepository>(
  (ref) => DefectiveMoveRepository(ref.watch(apiClientProvider)),
);

/// 当前用户能办理的不良品通道；权限变化(重新登录)时随会话重算。
final defectiveMoveOptionsProvider = FutureProvider.autoDispose<Set<String>>(
  (ref) => ref.watch(defectiveMoveRepositoryProvider).options(),
);
