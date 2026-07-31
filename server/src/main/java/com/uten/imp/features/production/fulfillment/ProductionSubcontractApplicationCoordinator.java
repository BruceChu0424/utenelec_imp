package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.features.production.mrp.MrpGenerateResult;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Production-side coordinator that binds a subcontract-owned application to
 * immutable material demands.
 */
@Service
@RequiredArgsConstructor
public class ProductionSubcontractApplicationCoordinator {

    private final ProductionSubcontractRequestPort subcontractRequests;
    private final ProductionFulfillmentLedgerService ledger;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(propagation = Propagation.MANDATORY)
    public MrpGenerateResult create(
            String productionPlanNo,
            LocalDate needDate,
            UUID warehouseId,
            ProductionPlanningPackage planningPackage,
            List<ProductionMaterialDemand> demands,
            List<ProductionSubcontractRequestPort.DraftLine> lines) {
        ProductionSubcontractRequestPort.DraftResult result =
                subcontractRequests.createProductionDraft(
                        productionPlanNo,
                        needDate,
                        warehouseId,
                        lines,
                        currentUser.requireId(),
                        currentUser.requireEmployeeId());
        if (result == null) {
            return null;
        }
        ledger.recordDocument(
                planningPackage.getId(),
                "SUBCONTRACT_APPLICATION",
                result.applicationId(),
                result.billNo(),
                currentUser.requireId());
        Map<UUID, ProductionMaterialDemand> demandById =
                demands.stream().collect(Collectors.toMap(
                        ProductionMaterialDemand::getId,
                        Function.identity()));
        for (ProductionSubcontractRequestPort.DraftLineResult line
                : result.lines()) {
            ProductionMaterialDemand demand =
                    demandById.get(line.demandId());
            if (demand == null) {
                throw new IllegalStateException(
                        "Subcontract application returned an unknown demand");
            }
            ledger.createSupplyPeg(
                    demand,
                    "SUBCONTRACT_APPLICATION_ITEM",
                    line.applicationItemId(),
                    line.qty(),
                    line.expectedDate());
        }
        return new MrpGenerateResult(
                result.applicationId(),
                result.billNo(),
                result.lines().size(),
                List.of());
    }
}
