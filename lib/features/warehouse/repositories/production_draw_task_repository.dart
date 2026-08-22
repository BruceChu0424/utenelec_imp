import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

class ProductionDrawTaskRepository {
  const ProductionDrawTaskRepository(this.api);

  final ApiClient api;

  /// READY/PARTIAL production DRAW tasks share the server open_qty projection.
  Future<int> pendingCount() async {
    final json = await api.get('/operations/workbench/warehouse/count');
    return (json['count'] as num?)?.toInt() ?? 0;
  }
}

final productionDrawTaskRepositoryProvider =
    Provider<ProductionDrawTaskRepository>(
      (ref) => ProductionDrawTaskRepository(ref.watch(apiClientProvider)),
    );
