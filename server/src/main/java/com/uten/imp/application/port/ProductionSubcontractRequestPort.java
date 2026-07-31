package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Neutral application boundary for production-created subcontract requests.
 *
 * <p>Production owns the demand; subcontract owns its documents. The immutable
 * demand id is returned with every created application item so production can
 * create an exact supply peg without importing subcontract entities.</p>
 */
public interface ProductionSubcontractRequestPort {

    DraftResult createProductionDraft(
            String productionPlanNo,
            LocalDate needDate,
            UUID warehouseId,
            List<DraftLine> lines,
            UUID applicantUserId,
            UUID makerEmployeeId);

    void closeGeneratedDraft(UUID applicationId, LifecycleAction action);

    enum LifecycleAction {
        CANCEL,
        REVERSE
    }

    record DraftLine(
            UUID demandId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal qty,
            LocalDate needDate,
            String remark) {
    }

    record DraftLineResult(
            UUID demandId,
            UUID applicationItemId,
            LocalDate expectedDate,
            BigDecimal qty) {
    }

    record DraftResult(
            UUID applicationId,
            String billNo,
            List<DraftLineResult> lines) {
    }
}
