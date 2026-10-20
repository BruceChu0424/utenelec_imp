import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

class MasterInlineEditRepository {
  MasterInlineEditRepository(this.api);
  final ApiClient api;

  Future<void> save(
    String entityType,
    String id, {
    required Map<String, dynamic> changes,
    required Map<String, Object?> expected,
  }) async {
    await api.patch(
      '/master/inline-edit/$entityType/${Uri.encodeComponent(id)}',
      body: {'expected': expected, 'changes': changes},
    );
  }

  /// The server merges ordinary fields under the original row version. Hidden
  /// values and precise decimals never pass through the browser's JSON numbers.
  Future<void> saveParty(
    String entityType,
    String id,
    Map<String, dynamic> changes, {
    required int? expectedVersion,
    bool Function()? isCurrent,
  }) async {
    if (expectedVersion == null) throw StateError('资料版本缺失，请刷新后重试');
    if (isCurrent?.call() == false) throw StateError('账号或权限已变化，请重新打开资料');
    await api.patch(
      '/master/inline-edit/$entityType/${Uri.encodeComponent(id)}',
      body: {
        'expected': {'version': expectedVersion},
        'changes': changes,
      },
    );
  }
}

final masterInlineEditRepositoryProvider = Provider<MasterInlineEditRepository>(
  (ref) => MasterInlineEditRepository(ref.watch(apiClientProvider)),
);
