import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

class MasterIdentifierRepository {
  const MasterIdentifierRepository(this.api);
  final ApiClient api;

  Future<String?> check(
    String resource,
    String code, {
    String? entityId,
    String? categoryId,
  }) async {
    if (code.trim().isEmpty) return null;
    final result = await api.get(
      '/master/$resource/code-availability',
      query: {
        'code': code.trim(),
        'entityId': ?entityId,
        if (categoryId?.isNotEmpty == true) 'categoryId': categoryId,
      },
    );
    return result['available'] == true
        ? null
        : result['message'] as String? ?? '编号已存在，请更换编号';
  }
}

final masterIdentifierRepositoryProvider = Provider<MasterIdentifierRepository>(
  (ref) => MasterIdentifierRepository(ref.watch(apiClientProvider)),
);
