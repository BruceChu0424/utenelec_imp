package com.uten.imp.application.port;

import java.math.BigDecimal;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Read-only production valuation evidence; never a BOM or goods-master estimate. */
public interface GoodsActualCostQueryPort {
    /** Dates select physical output business dates; inputs retain their entire original cost scope. */
    record Query(UUID goodsId, UUID executionSegmentId, LocalDate from, LocalDate to, UUID revisionId) {}

    record ActualCostSnapshot(UUID goodsId, OffsetDateTime capturedAt, String currencyBasis,
            String periodBasis, String inputScope, Query filter, Summary summary,
            List<CostObject> costObjects, List<InputLine> inputs, List<OutputLine> outputs,
            List<Revision> revisions, List<Gap> gaps) {}

    /** Compare a frozen estimate at outputQtyBase with allocatedOutputCostLocal, not total scope input. */
    record Summary(@JsonSerialize(using = ExactDecimalText.class) BigDecimal knownInputCostLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal allocatedOutputCostLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal scopeAllocatedOutputCostLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal excludedOutputCostLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal heldWipLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal pendingReallocationLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal unclassifiedLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal outputQtyBase, @JsonSerialize(using = ExactDecimalText.class) BigDecimal actualUnitCostLocal, boolean pending,
            boolean fullCostComplete, String coverageCode, long pendingSourceCount) {}

    record CostObject(UUID costObjectId, String scopeKind, UUID executionSegmentId, String executionNo,
            UUID revisionId, long revisionVersion, String state, @JsonSerialize(using = ExactDecimalText.class) BigDecimal targetQtyBase,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal scopeOutputQtyBase, @JsonSerialize(using = ExactDecimalText.class) BigDecimal knownInputCostLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal allocatedOutputCostLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal heldWipLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal pendingReallocationLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal unclassifiedLocal,
            boolean pending, boolean historicalRevision, List<String> pendingReasons) {}

    record InputLine(UUID costObjectId, UUID revisionId, UUID inputNodeId, long valueRevision,
            UUID approvedPostingId, String inputKind, String quantityBasis,
            UUID goodsId, String goodsCode, String goodsName, UUID unitId, String unitName,
            UUID warehouseId, UUID colorId, @JsonSerialize(using = ExactDecimalText.class) BigDecimal grossQtyBase, @JsonSerialize(using = ExactDecimalText.class) BigDecimal returnedQtyBase,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal netQtyBase, @JsonSerialize(using = ExactDecimalText.class) BigDecimal knownAmountLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal allocatedAmountLocal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal heldAmountLocal, @JsonSerialize(using = ExactDecimalText.class) BigDecimal exactAmountLower, @JsonSerialize(using = ExactDecimalText.class) BigDecimal exactAmountUpper,
            String amountBasis, String sourceDocType, UUID sourceDocId, UUID sourceItemId,
            OffsetDateTime occurredAt, boolean pending, boolean laterCostRevision) {}

    record OutputLine(UUID costObjectId, UUID revisionId, UUID sourceNodeId, long valueRevision,
            UUID movementId, UUID withdrawnMovementId, UUID warehouseId, UUID colorId,
            LocalDate businessDate, String sourceDocType, UUID sourceDocId, UUID sourceItemId,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal originalQtyBase, @JsonSerialize(using = ExactDecimalText.class) BigDecimal effectiveQtyBase, @JsonSerialize(using = ExactDecimalText.class) BigDecimal knownAmountLocal,
            boolean withdrawn, boolean pending, boolean laterCostRevision) {}

    record Revision(UUID costObjectId, UUID revisionId, long version, OffsetDateTime occurredAt,
            boolean scopeComplete, @JsonSerialize(using = ExactDecimalText.class) BigDecimal targetQtyBase, @JsonSerialize(using = ExactDecimalText.class) BigDecimal outputQtyBase,
            long pendingTaskCount, String sourceDocType, UUID sourceDocId, UUID sourceItemId) {}

    /** Codes are machine-readable; labels belong in the UI/export projection. */
    record Gap(String code, UUID costObjectId, UUID sourceId, String component) {}

    ActualCostSnapshot snapshot(Query query);
}
