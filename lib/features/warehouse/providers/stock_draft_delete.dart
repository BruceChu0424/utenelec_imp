import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

/// 独立草稿列表与任务中心内嵌草稿共用同一删除权限和状态门控。
bool canDeleteStockDrafts(Iterable<String> permissions) =>
    DocumentPermissionCatalog.stockDocument.allows(
      permissions,
      DocumentPermissionAction.delete,
    );

bool isStockDraftDeleteCandidate(StockDocListItem item) => item.status == 0;

/// 仅对本次选择的记录复核最新详情，阻止通用删除误伤生产链及永久调整记录。
Future<void> deleteStockDraft(
  WidgetRef ref, {
  required StockDocType type,
  required String id,
  required bool Function() isMounted,
  required bool Function() stillCurrent,
  Future<void> Function()? beforeDelete,
}) async {
  final scope = ref.read(authenticatedScopeProvider);
  bool hasDeletePermission() =>
      canDeleteStockDrafts(ref.read(currentPermissionsProvider));
  if (!hasDeletePermission() || !stillCurrent()) {
    throw ApiException('FORBIDDEN', '没有仓库单据删除权限');
  }
  final repository = ref.read(stockDocRepositoryProvider(type));
  final detail = await repository.detail(id);
  if (detail.status != 0) {
    throw ApiException('CONFLICT', '单据状态已变化，仅草稿可删除');
  }
  if (detail.productionLinked || !detail.canDelete) {
    throw ApiException(
      'CONFLICT',
      detail.restrictionReason ?? '该单据不能通过仓库草稿列表删除，请进入详情处理',
    );
  }
  if (!isMounted() ||
      !await loadDocumentOwnerCanWrite(
        ref,
        DocumentDataScope.stockDocument,
        detail.makerId,
      )) {
    throw ApiException('FORBIDDEN', documentScopeReadOnlyMessage);
  }
  if (!isMounted() ||
      ref.read(authenticatedScopeProvider) != scope ||
      !stillCurrent() ||
      !hasDeletePermission()) {
    throw ApiException('FORBIDDEN', '当前身份、选择范围或仓库单据删除权限已变化');
  }
  await beforeDelete?.call();
  if (!isMounted() ||
      ref.read(authenticatedScopeProvider) != scope ||
      !stillCurrent() ||
      !hasDeletePermission()) {
    throw ApiException('FORBIDDEN', '当前身份、选择范围或仓库单据删除权限已变化');
  }
  await repository.delete(id);
}
