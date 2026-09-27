import '../../../core/network/api_exception.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// 列表可选门控：不能把出货待财审等 status=0 的单据当成草稿。
bool isDeletableSalesDraftRow(SalesDocListItem row, SalesDocType type) =>
    type != SalesDocType.otherShipment &&
    row.writable &&
    row.status == kSalesStatusDraft &&
    row.legacyId == null &&
    !row.closed &&
    !row.stopped &&
    !row.financeRejected &&
    !row.rejected &&
    (!type.isShipment ||
        (!row.shipmentWorkflow.salesConfirmed &&
            salesShipmentStageOf(row) == SalesShipmentStage.draft));

/// 删除前重读最新状态与对象可写范围，再走原删除接口（服务端仍做最终并发校验）。
Future<void> deleteSalesDraft(
  SalesRepository repository,
  SalesDocType type,
  String id, {
  bool Function()? stillCurrent,
}) async {
  final detail = await repository.detail(id);
  if (stillCurrent != null && !stillCurrent()) {
    throw ApiException('DRAFT_DELETE_CONTEXT_CHANGED', '当前身份或选择范围已变化，请重新选择草稿');
  }
  final workflow = detail.shipmentWorkflow;
  if (type == SalesDocType.otherShipment ||
      !detail.writable ||
      detail.status != kSalesStatusDraft ||
      detail.legacyId != null ||
      detail.closed ||
      detail.stopped ||
      detail.financeRejected ||
      detail.rejected ||
      (type.isShipment &&
          (workflow.kind == 'LEGACY' ||
              workflow.salesConfirmed ||
              workflow.financeReviewPending ||
              workflow.financeRejected ||
              detail.financeAudit == 1))) {
    throw ApiException('DRAFT_DELETE_NOT_ALLOWED', '该单据已不是可删除草稿或无删除权限，请刷新核对');
  }
  await repository.delete(id);
}
