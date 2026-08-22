import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// Shared client for every master-data status-only command.
///
/// Callers pass the existing entity resource path (for example
/// `/api/master/colors/{id}`); this class owns the single `/status` contract so
/// nine pages do not duplicate networking code or fall back to stale full PUTs.
abstract interface class MasterStatusRepository {
  Future<void> change({
    required String resourcePath,
    required String status,
    int? version,
  });
}

class DioMasterStatusRepository implements MasterStatusRepository {
  DioMasterStatusRepository(this.api);

  final ApiClient api;

  @override
  Future<void> change({
    required String resourcePath,
    required String status,
    int? version,
  }) async {
    await api.patch(
      '$resourcePath/status',
      body: {'status': status, 'version': ?version},
    );
  }
}

final masterStatusRepositoryProvider = Provider<MasterStatusRepository>(
  (ref) => DioMasterStatusRepository(ref.watch(apiClientProvider)),
);
