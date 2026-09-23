// 单据普通写能力测试夹具(ADR-108): 写能力来自会话快照, 页面测试直接固定能力值。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';

/// 覆盖全部单据范围的写能力: [writeAll] = 可写全部负责人的单据;
/// [owners] = 只能写这些负责人的单据。
Override documentScopeOverride({
  bool writeAll = false,
  Set<String> owners = const {},
}) => documentScopeCapabilityProvider.overrideWith(
  (ref, scope) async => DocumentScopeCapability(
    scope: scope.apiValue,
    writeAll: writeAll,
    writableOwnerIds: owners,
  ),
);
