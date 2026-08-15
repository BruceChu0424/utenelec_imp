package com.uten.imp.features.production.mrp;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

/**
 * 生产预排草案服务：在草稿状态的生产计划上保存分段预排草案（按 requestHash +
 * 预览指纹幂等去重，旧草案置为 SUPERSEDED）；审核下达时以 {@link Propagation#MANDATORY}
 * 事务由 {@link #applyActive(UUID)} 原子转为正式 execution package。
 */
@Service
@RequiredArgsConstructor
public class ProductionPlanningDraftService {

    private static final short PLAN_STATUS_DRAFT = 0;

    private final ProductionPlanningDraftRepository draftRepo;
    private final ProductionPlanningRequestValidator validator;
    private final ProductionExecutionPackageCommandService executionCommand;
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ObjectMapper objectMapper;

    @Transactional
    public ProductionPlanningDraftView save(
            UUID planId,
            GeneratePlanningPackageRequest request) {
        tx.bind();
        ProductionPlan plan = lockDraftPlan(planId);
        String requestHash =
                ProductionExecutionPackageCommandService.requestHash(request);

        ProductionPlanningDraft active =
                draftRepo.lockActiveByPlanId(planId).orElse(null);
        if (active != null && plan.getMaterialAnalysisId() != null) {
            if (active.getRequestHash().equals(requestHash)) {
                return toView(active);
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "物料分析生成的正式计划不能改写预排分段；请取消后从物料分析重新生成");
        }
        ProductionPlanningRequestValidator.Validated validated =
                validator.validateCurrent(plan.getId(), request);
        if (active != null
                && active.getRequestHash().equals(requestHash)
                && active.getPreviewFingerprint().equalsIgnoreCase(validated.snapshot().fingerprint())) {
            return toView(active);
        }
        UUID actor = currentUser.requireId();
        if (active != null) {
            supersede(active, actor, "保存了新的预排草案");
            draftRepo.saveAndFlush(active);
        }

        ProductionPlanningDraft created = new ProductionPlanningDraft();
        created.setPlanId(planId);
        created.setWarehouseId(request.getWarehouseId());
        created.setPayload(objectMapper.valueToTree(request));
        created.setRequestHash(requestHash);
        created.setPreviewFingerprint(
                validated.snapshot().fingerprint().toLowerCase());
        created.setPlannedBy(actor);
        created.setPlannedAt(Instant.now());
        draftRepo.saveAndFlush(created);
        return toView(created);
    }

    @Transactional(readOnly = true)
    public Optional<ProductionPlanningDraftView> current(UUID planId) {
        return draftRepo.findByPlanIdAndStatus(
                        planId, ProductionPlanningDraft.STATUS_ACTIVE)
                .map(this::toView);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void supersedeActive(UUID planId, String reason) {
        ProductionPlanningDraft active =
                draftRepo.lockActiveByPlanId(planId).orElse(null);
        if (active == null) {
            return;
        }
        supersede(active, currentUser.requireId(), reason);
        draftRepo.saveAndFlush(active);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public Optional<PlanningPackageResult> applyActive(UUID planId) {
        ProductionPlanningDraft active =
                draftRepo.lockActiveByPlanId(planId).orElse(null);
        if (active == null) {
            return Optional.empty();
        }
        GeneratePlanningPackageRequest request = payload(active);
        validator.validateCurrent(planId, request);
        PlanningPackageResult result = executionCommand.confirm(planId, request);

        active.setStatus(ProductionPlanningDraft.STATUS_APPLIED);
        active.setAppliedPackageId(result.packageId());
        active.setResolvedBy(currentUser.requireId());
        active.setResolvedAt(Instant.now());
        active.setResolutionReason("生产计划审核时原子下达");
        draftRepo.saveAndFlush(active);
        return Optional.of(result);
    }

    private ProductionPlan lockDraftPlan(UUID planId) {
        ProductionPlan plan = em.find(
                ProductionPlan.class, planId, LockModeType.PESSIMISTIC_WRITE);
        if (plan == null || plan.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划单不存在");
        }
        if (plan.getStatus() == null
                || plan.getStatus() != PLAN_STATUS_DRAFT) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "仅草稿状态的生产计划可以保存预排草案");
        }
        if (plan.isStopped() || plan.isCanceled()) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "已中止或已取消的生产计划不能保存预排草案");
        }
        return plan;
    }

    private GeneratePlanningPackageRequest payload(
            ProductionPlanningDraft draft) {
        try {
            return objectMapper.treeToValue(
                    draft.getPayload(), GeneratePlanningPackageRequest.class);
        } catch (JsonProcessingException | IllegalArgumentException ex) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "预排草案内容损坏，不能审核下达，请重新保存预排草案");
        }
    }

    private ProductionPlanningDraftView toView(
            ProductionPlanningDraft draft) {
        GeneratePlanningPackageRequest request = payload(draft);
        int segmentCount = request.getSegments() == null
                ? 0
                : request.getSegments().size();
        boolean generatePurchase =
                request.isGeneratePurchaseRequest();
        return new ProductionPlanningDraftView(
                draft.getId(),
                draft.getPlanId(),
                draft.getWarehouseId(),
                draft.getStatus(),
                draft.getPreviewFingerprint(),
                segmentCount,
                generatePurchase,
                draft.getPlannedBy(),
                draft.getPlannedAt(),
                request);
    }

    private static void supersede(
            ProductionPlanningDraft draft,
            UUID actor,
            String reason) {
        draft.setStatus(ProductionPlanningDraft.STATUS_SUPERSEDED);
        draft.setResolvedBy(actor);
        draft.setResolvedAt(Instant.now());
        draft.setResolutionReason(reason);
        draft.setAppliedPackageId(null);
    }
}
