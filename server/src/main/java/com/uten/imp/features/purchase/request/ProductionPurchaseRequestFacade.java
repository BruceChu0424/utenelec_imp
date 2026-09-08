package com.uten.imp.features.purchase.request;

import com.uten.imp.application.port.OrganizationReferencePort;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.PurchaseGoodsSnapshot;
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

/**
 * Purchase-module port used by production planning.
 *
 * <p>Production passes immutable demand lines. This facade owns purchase
 * entities, document numbering and lifecycle checks; no purchase Repository or
 * Entity escapes the module.
 */
@Service
@RequiredArgsConstructor
public class ProductionPurchaseRequestFacade {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    private final PurchaseRequestRepository requestRepo;
    private final PurchaseRequestItemRepository itemRepo;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final OrganizationReferencePort organizationReferences;
    private final com.uten.imp.application.concurrency.FulfillmentMutationLocks mutationLocks;

    @Transactional(propagation = Propagation.MANDATORY)
    public DraftResult createProductionDraft(
            String productionPlanNo,
            UUID materialAnalysisId,
            LocalDate needDate,
            UUID warehouseId,
            List<DraftLine> requestedLines,
            UUID applicantEmployeeId,
            UUID makerEmployeeId) {
        List<DraftLine> lines = requestedLines == null
                ? List.of()
                : requestedLines.stream()
                .filter(Objects::nonNull)
                .sorted(Comparator
                        .comparing((DraftLine line) ->
                                new MaterialDimension(line.goodsId(), line.colorId()))
                        .thenComparing(DraftLine::demandId))
                .toList();
        if (lines.isEmpty()) {
            return null;
        }
        for (DraftLine line : lines) {
            requireValid(line);
        }

        PurchaseRequest request = new PurchaseRequest();
        request.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_REQUEST));
        request.setBillDate(BusinessTime.today());
        request.setNeedDate(needDate);
        request.setWarehouseId(warehouseId);
        request.setApplicantId(applicantEmployeeId);
        organizationReferences.findActiveEmployee(applicantEmployeeId)
                .map(OrganizationReferencePort.EmployeeReference::departmentId)
                .ifPresent(request::setDepartmentId);
        request.setMakerId(makerEmployeeId);
        request.setRemark(materialAnalysisId == null
                ? "生产计划 " + productionPlanNo + " 未覆盖物料自动生成"
                : productionPlanNo + " 备料任务自动生成");
        request.setSourceDocNo(productionPlanNo);
        request.setStatus(STATUS_APPROVED);
        var createdSource=new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource(
                com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType.PURCHASE_REQUEST,request.getId());
        mutationLocks.expectCreatedSource(createdSource);
        requestRepo.save(request);

        List<DraftLineResult> created = new ArrayList<>(lines.size());
        Map<UUID, PurchaseGoodsSnapshot> goodsSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(DraftLine::goodsId).toList(),
                        PurchaseGoodsSnapshot.MASTER_AT_APPROVAL);
        OffsetDateTime snapshotLockedAt = OffsetDateTime.now();
        int lineNo = 0;
        for (DraftLine line : lines) {
            lineNo++;
            PurchaseRequestItem item = new PurchaseRequestItem();
            item.setRequestId(request.getId());
            item.setBillNo(request.getBillNo());
            item.setBillDate(request.getBillDate());
            item.setLineNo(lineNo);
            item.setGoodsId(line.goodsId());
            PurchaseGoodsSnapshot goodsSnapshot = PurchaseGoodsSnapshot.require(
                    goodsSnapshots, line.goodsId(), "生产计划采购申请明细");
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
            item.setGiftQty(BigDecimal.ZERO);
            item.setDeliverDate(line.needDate() == null ? needDate : line.needDate());
            item.setProductionPlanNo(productionPlanNo);
            item.setSourceDocNo(productionPlanNo);
            // 谱系打通：让采购员在申请/订货上直接看到「为哪些销售订单备料」（SOP 溯源要求）。
            // 计划路径沿 plan_order_item_links 回溯；物料分析路径按分析 id 沿分析行回溯。
            item.setSalesOrderNo(resolveSalesOrderNos(productionPlanNo, materialAnalysisId));
            item.setRemark(line.remark());
            itemRepo.save(item);
            created.add(new DraftLineResult(
                    line.demandId(),
                    item.getId(),
                    item.getDeliverDate(),
                    item.getQty()));
        }
        request.setTotalOriginal(BigDecimal.ZERO);
        request.setTotalLocal(BigDecimal.ZERO);
        requestRepo.save(request);
        itemRepo.flush();
        requestRepo.flush();
        mutationLocks.registerCreatedSource(createdSource);
        return new DraftResult(
                request.getId(), request.getBillNo(), List.copyOf(created));
    }

    /**
     * 由来源解析关联销售订单号（去重、"、"连接；超过 3 张显示"等 N 张"）。
     * 找不到关联（如手工计划、无销售来源的内部需求）返回 null，不阻塞申请生成。
     */
    private String resolveSalesOrderNos(String productionPlanNo, UUID materialAnalysisId) {
        if (materialAnalysisId != null) {
            return joinSalesOrderNos(em.createNativeQuery("""
                            SELECT DISTINCT so.bill_no
                            FROM production_material_analysis_items a
                            JOIN sales_order_items soi ON soi.id = a.sales_order_item_id
                            JOIN sales_orders so ON so.id = soi.order_id
                                 AND COALESCE(so.is_deleted, false) = false
                            WHERE a.analysis_id = :analysisId
                            ORDER BY 1
                            """)
                    .setParameter("analysisId", materialAnalysisId)
                    .getResultList());
        }
        if (productionPlanNo == null || productionPlanNo.isBlank()) return null;
        return joinSalesOrderNos(em.createNativeQuery("""
                        SELECT DISTINCT so.bill_no
                        FROM production_plans p
                        JOIN production_plan_items pi ON pi.plan_id = p.id
                             AND COALESCE(pi.is_deleted, false) = false
                        JOIN plan_order_item_links l ON l.plan_item_id = pi.id
                             AND COALESCE(l.is_deleted, false) = false
                        JOIN sales_order_items soi ON soi.id = l.order_item_id
                        JOIN sales_orders so ON so.id = soi.order_id
                             AND COALESCE(so.is_deleted, false) = false
                        WHERE p.bill_no = :no AND p.is_deleted = false
                        ORDER BY 1
                        """)
                .setParameter("no", productionPlanNo)
                .getResultList());
    }

    private static String joinSalesOrderNos(List<?> billNos) {
        if (billNos.isEmpty()) return null;
        List<String> distinct = billNos.stream()
                .map(String::valueOf).distinct().toList();
        if (distinct.size() <= 3) return String.join("、", distinct);
        return String.join("、", distinct.subList(0, 3)) + " 等 " + distinct.size() + " 张";
    }

    /**
     * Closes one generated request without erasing approved history.
     * CANCEL is a draft-only soft delete; approved sources require REVERSE.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void cancelGeneratedDraft(UUID requestId, LifecycleAction action) {
        PurchaseRequest request = em.find(
                PurchaseRequest.class, requestId, LockModeType.PESSIMISTIC_WRITE);
        if (request == null || request.isDeleted()) {
            if (action == LifecycleAction.CANCEL) {
                return;
            }
            throw new ApiException(ErrorCode.CONFLICT, "计划包关联采购申请不存在");
        }
        // ADR-065：申请可由同批多个备料任务共享，整批撤回时红冲幂等。
        if (action == LifecycleAction.REVERSE && request.getStatus() == STATUS_REVERSED) {
            return;
        }
        List<Object[]> items = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, COALESCE(ordered_qty, 0)
                                FROM purchase_request_items
                                WHERE request_id = :requestId
                                  AND is_deleted = FALSE
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("requestId", requestId));
        if (items.stream().anyMatch(row -> decimal(row[1]).signum() > 0)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包采购申请已经转采购订单，必须先反向处理下游订货");
        }

        if (action == LifecycleAction.CANCEL) {
            com.uten.imp.common.web.StandardDocumentLifecycleCapabilities
                    .requireDraftForDelete(request.getStatus());
            request.setDeleted(true);
            request.setDeletedAt(OffsetDateTime.now());
        } else {
            if (request.getStatus() != STATUS_DRAFT
                    && request.getStatus() != STATUS_APPROVED
                    && request.getStatus() != STATUS_REVERSED) {
                throw new ApiException(ErrorCode.CONFLICT, "采购申请状态不允许红冲");
            }
            request.setStatus(STATUS_REVERSED);
            request.setClosed(true);
        }
        requestRepo.save(request);
    }

    private static void requireValid(DraftLine line) {
        if (line.demandId() == null
                || line.goodsId() == null
                || line.unitId() == null
                || line.qty() == null
                || line.qty().signum() <= 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "采购需求草稿行缺少必填字段或数量无效");
        }
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) {
            return BigDecimal.ZERO;
        }
        if (value instanceof BigDecimal decimal) {
            return decimal;
        }
        return new BigDecimal(value.toString());
    }

    public enum LifecycleAction {
        CANCEL,
        REVERSE
    }

    public record MaterialDimension(UUID goodsId, UUID colorId)
            implements Comparable<MaterialDimension> {
        public MaterialDimension {
            if (goodsId == null) {
                throw new IllegalArgumentException("goodsId is required");
            }
        }

        @Override
        public int compareTo(MaterialDimension other) {
            int goods = goodsId.toString().compareTo(other.goodsId.toString());
            if (goods != 0) {
                return goods;
            }
            String left = colorId == null ? "" : colorId.toString();
            String right = other.colorId == null ? "" : other.colorId.toString();
            return left.compareTo(right);
        }
    }

    public record DraftLine(
            UUID demandId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal qty,
            LocalDate needDate,
            String remark) {
    }

    public record DraftLineResult(
            UUID demandId,
            UUID requestItemId,
            LocalDate expectedDate,
            BigDecimal qty) {
    }

    public record DraftResult(
            UUID requestId,
            String billNo,
            List<DraftLineResult> lines) {
    }
}
