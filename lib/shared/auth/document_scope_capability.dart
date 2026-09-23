import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session_snapshot_provider.dart';

/// Server-whitelisted document owner scopes. Keep values aligned with
/// DocumentScopeCapabilityService; arbitrary caller-provided scopes are not accepted.
enum DocumentDataScope {
  sales('sales'),
  finance('finance'),
  purchase('purchase'),
  subcontract('subcontract'),
  productionPlan('production_plan'),
  stockDocument('stock_doc');

  const DocumentDataScope(this.apiValue);
  final String apiValue;
}

const documentScopeReadOnlyMessage = '该单据当前仅可查看；如需修改，请由负责人操作或先完成正式数据交接';

class DocumentScopeCapability {
  const DocumentScopeCapability({
    required this.scope,
    required this.writeAll,
    required this.writableOwnerIds,
  });

  final String scope;
  final bool writeAll;
  final Set<String> writableOwnerIds;

  bool canWrite(String? ownerEmployeeId) {
    final owner = ownerEmployeeId?.trim();
    if (owner == null || owner.isEmpty) return false;
    return writeAll || writableOwnerIds.contains(owner);
  }

  factory DocumentScopeCapability.fromJson(Map<String, dynamic> json) {
    final scope = json['scope'];
    final writeAll = json['writeAll'];
    final rawOwners = json['writableOwnerIds'];
    if (scope is! String ||
        scope.trim().isEmpty ||
        writeAll is! bool ||
        rawOwners is! List) {
      throw const FormatException('Malformed document scope capability');
    }
    final owners = <String>{};
    for (final value in rawOwners) {
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('Malformed writable owner id');
      }
      owners.add(value.trim());
    }
    return DocumentScopeCapability(
      scope: scope.trim(),
      writeAll: writeAll,
      writableOwnerIds: Set.unmodifiable(owners),
    );
  }
}

/// 当前主体在某单据范围的普通写能力, 取自会话快照(ADR-108): 不再逐页请求
/// /auth/me/document-scopes/{scope}, 也不在详情页每次加载时作废重拉。
/// 登录/切身份/授权变化时快照自己重建。调用方必须把加载中与失败当只读处理。
final documentScopeCapabilityProvider = FutureProvider.autoDispose
    .family<DocumentScopeCapability, DocumentDataScope>((ref, scope) async {
      final snapshot = await ref.watch(sessionSnapshotProvider.future);
      return snapshot?.documentScopes[scope] ??
          DocumentScopeCapability(
            scope: scope.apiValue,
            writeAll: false,
            writableOwnerIds: const {},
          );
    });

bool documentOwnerCanWrite(
  AsyncValue<DocumentScopeCapability> capability,
  String? ownerEmployeeId,
) => capability.maybeWhen(
  data: (value) => value.canWrite(ownerEmployeeId),
  orElse: () => false,
);

/// Direct edit routes must not render an editable fallback while capability is
/// loading or unavailable. A failed capability request is therefore read-only.
Future<bool> loadDocumentOwnerCanWrite(
  WidgetRef ref,
  DocumentDataScope scope,
  String? ownerEmployeeId,
) async {
  try {
    final capability = await ref.read(
      documentScopeCapabilityProvider(scope).future,
    );
    return capability.canWrite(ownerEmployeeId);
  } catch (_) {
    return false;
  }
}
