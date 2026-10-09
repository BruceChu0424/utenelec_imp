package com.uten.imp.features.subcontract.application;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Subcontract-owned adapter for production-generated application drafts. */
@Service
@RequiredArgsConstructor
public class ProductionSubcontractRequestFacade
        implements ProductionSubcontractRequestPort {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final SubcontractApplicationRepository applicationRepo;
    private final SubcontractApplicationItemRepository itemRepo;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.application.concurrency.FulfillmentMutationLocks mutationLocks;

    /**
     * Closes one generated application without erasing approved history.
     * CANCEL is a draft-only soft delete; approved sources require REVERSE.
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public DraftResult createProductionDraft(
            String productionPlanNo,
            UUID materialAnalysisId,
            LocalDate needDate,
            UUID warehouseId,
            List<DraftLine> requestedLines,
            UUID applicantEmployeeId,
            UUID makerEmployeeId) {
        List<DraftLine> lines = sortedLines(requestedLines);
        if (lines.isEmpty()) {
            return null;
        }

        SubcontractApplication application =
                new SubcontractApplication();
        application.setBillNo(
                docNumberService.nextNumber(
                        DocNumberPrefix.SUB_APPLICATION));
        application.setBillDate(BusinessTime.today());
        application.setWarehouseId(warehouseId);
        application.setSupplierId(null);
        application.setApplicantId(applicantEmployeeId);
        application.setMakerId(makerEmployeeId);
        application.setNeedDate(needDate);
        application.setSourceDocNo(productionPlanNo);
        application.setRemark(materialAnalysisId == null
                ? "生产计划 " + productionPlanNo
                        + " 委外来源物料缺口自动生成；供应商待委外部门确认"
                : productionPlanNo + " 委外备料任务自动生成；供应商待委外部门确认");
        application.setTotalOriginal(BigDecimal.ZERO);
        application.setTotalLocal(BigDecimal.ZERO);
        application.setStatus(STATUS_APPROVED);
        var createdSource=new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource(
                com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType.SUBCONTRACT_APPLICATION,application.getId());
        mutationLocks.expectCreatedSource(createdSource);
        applicationRepo.save(application);

        List<DraftLineResult> created = insertDemandItems(
                application, lines, productionPlanNo, needDate, 0);
        itemRepo.flush();
        applicationRepo.flush();
        mutationLocks.registerCreatedSource(createdSource);
        return new DraftResult(
                application.getId(),
                application.getBillNo(),
                List.copyOf(created));
    }

    /** ADR-065 修订三（滚动合单）：与本分析挂钩、全部明细未被下游动过的最近一张申请。 */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public MergeableDraft findMergeableProductionDraft(UUID materialAnalysisId, int incomingLines) {
        if (materialAnalysisId == null) return null;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT application.id, application.bill_no
                        FROM subcontract_applications application
                        WHERE application.id IN (
                                SELECT action.external_document_id
                                FROM preplan_supply_actions action
                                WHERE action.analysis_id = :analysisId
                                  AND action.route = 'SUBCONTRACT'
                                  AND action.operation_type = 'SUPPLY'
                                  AND action.status <> 'CANCELLED'
                                  AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                                  AND action.external_document_id IS NOT NULL)
                          AND COALESCE(application.is_deleted, FALSE) = FALSE
                          AND application.status IN (0, 1)
                          AND COALESCE(application.is_closed, FALSE) = FALSE
                          AND NOT EXISTS (
                                SELECT 1 FROM subcontract_application_items item
                                WHERE item.application_id = application.id
                                  AND COALESCE(item.is_deleted, FALSE) = FALSE
                                  AND COALESCE(item.ordered_qty, 0) > 0)
                          AND NOT EXISTS (
                                SELECT 1 FROM subcontract_order_item_sources source
                                JOIN subcontract_order_items order_item
                                  ON order_item.id = source.order_item_id
                                 AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                                JOIN subcontract_orders header
                                  ON header.id = order_item.order_id
                                 AND COALESCE(header.is_deleted, FALSE) = FALSE
                                JOIN subcontract_application_items item
                                  ON item.id = source.application_item_id
                                WHERE item.application_id = application.id)
                          AND (SELECT COUNT(*) FROM subcontract_application_items item
                               WHERE item.application_id = application.id
                                 AND COALESCE(item.is_deleted, FALSE) = FALSE)
                              + :incomingLines
                              <= :maxLines
                        ORDER BY application.created_at DESC, application.id DESC
                        LIMIT 1
                        """)
                .setParameter("analysisId", materialAnalysisId)
                .setParameter("incomingLines", incomingLines)
                .setParameter("maxLines",
                        com.uten.imp.common.validation.RequestLimits.DOCUMENT_LINES));
        if (rows.isEmpty()) return null;
        return new MergeableDraft((UUID) rows.getFirst()[0], (String) rows.getFirst()[1]);
    }

    /** ADR-065 修订三：把明细行并入既有委外申请；任一明细已被下游动过即拒绝。 */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public DraftResult appendProductionDraftLines(
            UUID applicationId,
            String productionPlanNo,
            UUID materialAnalysisId,
            List<DraftLine> requestedLines) {
        List<DraftLine> lines = sortedLines(requestedLines);
        if (lines.isEmpty()) {
            return null;
        }
        SubcontractApplication application = em.find(
                SubcontractApplication.class, applicationId, LockModeType.PESSIMISTIC_WRITE);
        if (application == null || application.isDeleted()
                || application.getStatus() == null
                || (application.getStatus() != STATUS_DRAFT && application.getStatus() != STATUS_APPROVED)
                || application.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外申请已结案、红冲或删除，不能并入明细");
        }
        Number ordered = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM subcontract_application_items
                WHERE application_id = :applicationId AND is_deleted = FALSE
                  AND COALESCE(ordered_qty, 0) > 0
                """).setParameter("applicationId", applicationId).getSingleResult();
        if (ordered.longValue() > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外申请已有明细订货，不能并入明细，请另立申请");
        }
        Number referenced = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM subcontract_order_item_sources source
                JOIN subcontract_order_items order_item
                  ON order_item.id = source.order_item_id
                 AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                JOIN subcontract_orders header
                  ON header.id = order_item.order_id
                 AND COALESCE(header.is_deleted, FALSE) = FALSE
                JOIN subcontract_application_items item
                  ON item.id = source.application_item_id
                 AND item.application_id = :applicationId AND item.is_deleted = FALSE
                """).setParameter("applicationId", applicationId).getSingleResult();
        if (referenced.longValue() > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外申请明细已被订货单引用，不能并入明细，请另立申请");
        }
        int startLineNo = ((Number) em.createNativeQuery("""
                        SELECT COALESCE(MAX(line_no), 0) FROM subcontract_application_items
                        WHERE application_id = :applicationId
                        """)
                .setParameter("applicationId", applicationId).getSingleResult()).intValue();
        LocalDate earliest = lines.stream()
                .map(DraftLine::needDate).filter(Objects::nonNull)
                .reduce(ProductionSubcontractRequestFacade::earliest).orElse(null);
        if (earliest != null
                && (application.getNeedDate() == null || earliest.isBefore(application.getNeedDate()))) {
            application.setNeedDate(earliest);
            applicationRepo.save(application);
        }
        List<DraftLineResult> created = insertDemandItems(
                application, lines, productionPlanNo, application.getNeedDate(), startLineNo);
        itemRepo.flush();
        applicationRepo.flush();
        return new DraftResult(
                application.getId(), application.getBillNo(), List.copyOf(created));
    }

    /** 排序 + 过滤 + 校验，create 与 append 共用的入口形态。 */
    private static List<DraftLine> sortedLines(List<DraftLine> requestedLines) {
        List<DraftLine> lines = requestedLines == null
                ? List.of()
                : requestedLines.stream()
                        .filter(Objects::nonNull)
                        .sorted(Comparator
                                .comparing(DraftLine::goodsId)
                                .thenComparing(line ->
                                        Objects.toString(line.colorId(), ""))
                                .thenComparing(DraftLine::demandId))
                        .toList();
        lines.forEach(ProductionSubcontractRequestFacade::validate);
        return lines;
    }

    private static LocalDate earliest(LocalDate left, LocalDate right) {
        if (left == null) return right;
        if (right == null) return left;
        return left.isBefore(right) ? left : right;
    }

    /** create 与 append 共用的明细写入：逐行货品快照、来源标签与锚定回执保持同一形态。 */
    private List<DraftLineResult> insertDemandItems(
            SubcontractApplication application,
            List<DraftLine> lines,
            String productionPlanNo,
            LocalDate headerNeedDate,
            int startLineNo) {
        OffsetDateTime snapshotLockedAt = OffsetDateTime.now();
        Map<UUID, SubcontractGoodsSnapshot> goodsSnapshots =
                SubcontractGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(DraftLine::goodsId).toList(),
                        SubcontractGoodsSnapshot.MASTER_AT_APPROVAL);
        List<DraftLineResult> created = new ArrayList<>();
        int lineNo = startLineNo;
        for (DraftLine line : lines) {
            SubcontractApplicationItem item =
                    new SubcontractApplicationItem();
            item.setApplicationId(application.getId());
            item.setBillNo(application.getBillNo());
            item.setBillDate(application.getBillDate());
            item.setLineNo(++lineNo);
            item.setGoodsId(line.goodsId());
            SubcontractGoodsSnapshot goodsSnapshot = SubcontractGoodsSnapshot.require(
                    goodsSnapshots, line.goodsId(), "生产计划委外申请明细");
            item.setGoodsCodeSnapshot(goodsSnapshot.code());
            item.setGoodsNameSnapshot(goodsSnapshot.name());
            item.setGoodsSnapshotSource(goodsSnapshot.source());
            item.setGoodsSnapshotLockedAt(snapshotLockedAt);
            item.setColorId(line.colorId());
            item.setUnitId(line.unitId());
            item.setUnitRate(BigDecimal.ONE);
            item.setQty(line.qty());
            item.setPrice(BigDecimal.ZERO);
            item.setAmountOriginal(BigDecimal.ZERO);
            item.setAmountLocal(BigDecimal.ZERO);
            item.setOrderedQty(BigDecimal.ZERO);
            item.setSourceDocNo(productionPlanNo);
            item.setRemark(line.remark());
            itemRepo.save(item);
            created.add(new DraftLineResult(
                    line.demandId(),
                    item.getId(),
                    line.needDate() == null ? headerNeedDate : line.needDate(),
                    line.qty()));
        }
        return created;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void increaseProductionDraftLine(
            UUID applicationId, UUID applicationItemId, BigDecimal addedQty) {
        if (addedQty == null || addedQty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "追加数量必须大于 0");
        }
        SubcontractApplication application = em.find(
                SubcontractApplication.class, applicationId, LockModeType.PESSIMISTIC_WRITE);
        if (application == null || application.isDeleted()
                || application.getStatus() == null
                || (application.getStatus() != STATUS_DRAFT && application.getStatus() != STATUS_APPROVED)
                || application.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT, "委外申请已结案、红冲或删除，不能就地追加数量");
        }
        SubcontractApplicationItem item = em.find(
                SubcontractApplicationItem.class, applicationItemId, LockModeType.PESSIMISTIC_WRITE);
        Number live = item == null ? 0 : (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM subcontract_application_items
                WHERE id = :itemId AND application_id = :applicationId AND is_deleted = FALSE
                """).setParameter("itemId", applicationItemId)
                .setParameter("applicationId", applicationId).getSingleResult();
        if (item == null || live.longValue() == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "委外申请明细不存在或不属于该申请");
        }
        if (item.getOrderedQty() != null && item.getOrderedQty().signum() > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外申请明细已订货，不能就地追加数量，请另立申请");
        }
        item.setQty(item.getQty().add(addedQty));
        itemRepo.save(item);
        itemRepo.flush();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void closeGeneratedDraft(
            UUID applicationId, LifecycleAction action) {
        SubcontractApplication application = em.find(
                SubcontractApplication.class,
                applicationId,
                LockModeType.PESSIMISTIC_WRITE);
        if (application == null || application.isDeleted()) {
            if (action == LifecycleAction.CANCEL) {
                return;
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包关联的委外申请不存在");
        }
        // ADR-065：申请可由同批多个备料任务共享，整批撤回时红冲幂等。
        if (action == LifecycleAction.REVERSE
                && application.getStatus() == STATUS_REVERSED) {
            return;
        }
        List<Object[]> items = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, COALESCE(ordered_qty, 0)
                                FROM subcontract_application_items
                                WHERE application_id = :applicationId
                                  AND is_deleted = FALSE
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter(
                                "applicationId", applicationId));
        if (items.stream().anyMatch(
                row -> decimal(row[1]).signum() > 0)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包委外申请已转委外订单，请先红冲下游的委外订货单");
        }
        if (action == LifecycleAction.CANCEL) {
            com.uten.imp.common.web.StandardDocumentLifecycleCapabilities
                    .requireDraftForDelete(application.getStatus());
            application.setDeleted(true);
            application.setDeletedAt(OffsetDateTime.now());
        } else {
            if (application.getStatus() != STATUS_DRAFT
                    && application.getStatus() != STATUS_APPROVED
                    && application.getStatus() != STATUS_REVERSED) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "委外申请状态不允许红冲");
            }
            application.setStatus(STATUS_REVERSED);
            application.setClosed(true);
        }
        applicationRepo.save(application);
    }

    private static void validate(DraftLine line) {
        if (line.demandId() == null
                || line.goodsId() == null
                || line.unitId() == null
                || line.qty() == null
                || line.qty().signum() <= 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "委外需求行填写不完整或数量不正确");
        }
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }
}
