package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SubcontractPreparationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.ProductView;
import com.uten.imp.features.production.analysis.SubcontractPreparationContracts.StartRequest;
import com.uten.imp.features.production.analysis.SubcontractPreparationContracts.StartResult;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@RequiredArgsConstructor
public class SubcontractPreparationCoordinator {

    private final SubcontractPreparationPort preparation;
    private final MaterialAnalysisService analyses;
    private final SubcontractPreparationEntitlementHandoffService handoffs;
    private final SecurityContextCurrentUser currentUser;

    @Transactional
    public StartResult start(java.util.UUID planItemId, StartRequest request) {
        SubcontractPreparationPort.StartContext startContext =
                preparation.prepareStart(planItemId, request.warehouseId());
        handoffs.lockStartContext(startContext);
        SubcontractPreparationPort.StartClaim claim = preparation.beginStart(
                 planItemId, request.expectedVersion(), request.idempotencyKey(),
                 request.warehouseId(), startContext);
        if (claim.replay()) {
            handoffs.requireReplayComplete(claim);
            return toResult(preparation.completeStart(
                    claim, claim.replayAnalysisId(), claim.replayAnalysisItemId(),
                    currentUser.requireId()));
        }
        String sourceRef = "SC-PREP:" + claim.orderItemId();
        AnalysisView analysis = analyses.previewSubcontractPreparation(new PreviewRequest(
                null, null, null, claim.warehouseId(),
                "SC-PREP:" + claim.planItemId(),
                List.of(new PreviewItem(
                        "SUBCONTRACT_PREPARATION", null,
                        claim.goodsId(), claim.colorId(), claim.unitId(),
                        sourceRef,
                        "委外订货 " + claim.orderBillNo()
                                + " 的目标件需先完成内部自制并经仓库实收入库",
                        claim.needDate(), claim.requiredQty()))));
        ProductView source = analysis.products().stream()
                .filter(product -> "SUBCONTRACT_PREPARATION".equals(product.sourceType()))
                .filter(product -> sourceRef.equals(product.sourceRef()))
                .findFirst()
                 .orElseThrow(() -> new ApiException(
                        ErrorCode.CONFLICT,
                         "物料分析已创建但缺少委外前置自制来源行"));
        handoffs.createStartHandoff(
                claim, analysis.analysisId(), source.analysisLineId());
        return toResult(preparation.completeStart(
                claim, analysis.analysisId(), source.analysisLineId(),
                currentUser.requireId()));
    }

    private boolean hasAuthority(String authority) {
        AuthUser user = currentUser.get().orElse(null);
        return user != null && (user.isSuperAdmin() || user.getAuthorities().stream()
                .anyMatch(granted -> authority.equals(granted.getAuthority())));
    }


    private static StartResult toResult(SubcontractPreparationPort.StartResult result) {
        return new StartResult(result.planItemId(), result.status(), result.analysisId(),
                 result.analysisItemId(), result.version(),
                 result.sourceAnalysisId(), result.sourceMaterialLineId(),
                 result.handoffId(), result.handoffStatus(), result.takeoverQty(),
                 result.handedOffEntitlementQty());
    }
}
