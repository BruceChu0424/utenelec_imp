// ADR-156 委外申请明细的物料齐套情况：GET /api/subcontract/applications/items/{id}/kit。
//
// 页面只依赖 [SubcontractKitGateway]，测试用假实现替换；数量一律由服务端算好。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/subcontract_application_kit.dart';

abstract interface class SubcontractKitGateway {
  /// 这条委外申请明细的齐套情况(只读)。
  Future<SubcontractApplicationKit> applicationKit(String applicationItemId);
}

class SubcontractKitRepository implements SubcontractKitGateway {
  const SubcontractKitRepository(this.api);

  final ApiClient api;

  @override
  Future<SubcontractApplicationKit> applicationKit(
    String applicationItemId,
  ) async => SubcontractApplicationKit.fromJson(
    await api.get(
      ApiEndpoints.subcontractApplicationItemKit(applicationItemId),
    ),
  );
}

final subcontractKitRepositoryProvider = Provider<SubcontractKitGateway>(
  (ref) => SubcontractKitRepository(ref.watch(apiClientProvider)),
);
