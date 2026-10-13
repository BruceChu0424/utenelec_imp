package com.uten.imp.application.port;

import java.util.UUID;

/** Same-transaction value hooks after the corresponding immutable commercial/quality facts exist. */
public interface ProcurementInventoryValuePort {
    void receiptApproved(String receiptType,UUID receiptId,UUID actorUserId);
    void qualityRecorded(UUID inspectionEventId,UUID actorUserId);
    /** Ordered events from one locked quality command; all writes remain in its transaction. */
    default void qualityRecordedBatch(java.util.List<UUID> inspectionEventIds,UUID actorUserId) {
        inspectionEventIds.forEach(event -> qualityRecorded(event,actorUserId));
    }
    void receiptReversed(String receiptType,UUID receiptId,UUID actorUserId);
    void qualityReversed(UUID inspectionEventId,UUID actorUserId);
    void creditConfirmed(UUID creditDocumentId,UUID actorUserId);
    void creditReversed(UUID originalCreditDocumentId,UUID actorUserId);
    void returnedToSupplier(UUID failureCaseId,UUID actorUserId);
    void returnReversed(UUID failureCaseId,UUID actorUserId);
    record CostScopePin(UUID scopeId,long currentVersion){}
    record CostWithdrawalPreview(UUID receiptId,java.util.List<CostScopePin> scopes,String factsSnapshot){
        public CostWithdrawalPreview { scopes=java.util.List.copyOf(scopes);if(receiptId==null||factsSnapshot==null||!factsSnapshot.matches("[a-f0-9]{64}"))throw new IllegalArgumentException("Invalid internal cost withdrawal proof"); }
    }
    default String requireReceiptReversible(String type,UUID receiptId){throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"当前无法核对原收货成本来源");}
    default CostWithdrawalPreview previewReceiptCostWithdrawal(String type,UUID id){throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"当前无法核对委外收货专用成本释放");}
}
