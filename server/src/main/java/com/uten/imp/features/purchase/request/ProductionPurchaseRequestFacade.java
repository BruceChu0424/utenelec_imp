package com.uten.imp.features.purchase.request;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashMap;
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

    /**
     * Locks currently open purchase supply in stable header/item UUID order.
     * The returned snapshot is advisory only until an explicit supply peg is
     * persisted; matching dimensions never allocate a PO implicitly.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public Map<MaterialDimension, OpenSupply> lockOpenSupply(
            Collection<MaterialDimension> requestedDimensions) {
        List<MaterialDimension> dimensions = requestedDimensions == null
                ? List.of()
                : requestedDimensions.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (dimensions.isEmpty()) {
            return Map.of();
        }
        List<UUID> goodsIds = dimensions.stream()
                .map(MaterialDimension::goodsId)
                .distinct()
                .sorted()
                .toList();

        // Header before item is the shared purchase lock order.
        em.createNativeQuery("""
                        SELECT o.id
                        FROM purchase_orders o
                        WHERE o.status = 1
                          AND o.is_deleted = FALSE
                          AND COALESCE(o.is_stopped, FALSE) = FALSE
                          AND o.is_closed = FALSE
                          AND EXISTS (
                              SELECT 1
                              FROM purchase_order_items i
                              WHERE i.order_id = o.id
                                AND i.is_deleted = FALSE
                                AND i.goods_id IN (:goodsIds)
                          )
                        ORDER BY o.id
                        FOR UPDATE OF o
                        """)
                .setParameter("goodsIds", goodsIds)
                .getResultList();

        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT i.id, i.goods_id, i.color_id,
                                       COALESCE(i.qty, 0),
                                       COALESCE(i.received_qty, 0),
                                       COALESCE(i.returned_qty, 0),
                                       COALESCE(i.unit_rate, 1),
                                       COALESCE(i.deliver_date, o.deliver_date)
                                FROM purchase_order_items i
                                JOIN purchase_orders o ON o.id = i.order_id
                                WHERE o.status = 1
                                  AND o.is_deleted = FALSE
                                  AND COALESCE(o.is_stopped, FALSE) = FALSE
                                  AND o.is_closed = FALSE
                                  AND i.is_deleted = FALSE
                                  AND i.goods_id IN (:goodsIds)
                                ORDER BY i.id
                                FOR UPDATE OF i
                                """)
                        .setParameter("goodsIds", goodsIds));

        Map<MaterialDimension, OpenSupplyAccumulator> totals = new LinkedHashMap<>();
        for (Object[] row : rows) {
            MaterialDimension dimension =
                    new MaterialDimension((UUID) row[1], (UUID) row[2]);
            if (!dimensions.contains(dimension)) {
                continue;
            }
            BigDecimal rate = decimal(row[6]);
            if (rate.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "开放采购订单存在无效单位换算率");
            }
            BigDecimal open = decimal(row[3])
                    .subtract(decimal(row[4]))
                    .add(decimal(row[5]))
                    .max(BigDecimal.ZERO)
                    .multiply(rate);
            if (open.signum() <= 0) {
                continue;
            }
            LocalDate expected = localDate(row[7]);
            totals.computeIfAbsent(dimension, ignored -> new OpenSupplyAccumulator())
                    .add(open, expected);
        }
        Map<MaterialDimension, OpenSupply> result = new LinkedHashMap<>();
        dimensions.forEach(dimension -> {
            OpenSupplyAccumulator value = totals.get(dimension);
            result.put(
                    dimension,
                    value == null
                            ? new OpenSupply(BigDecimal.ZERO, null)
                            : value.toValue());
        });
        return result;
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public DraftResult createProductionDraft(
            String productionPlanNo,
            LocalDate needDate,
            UUID warehouseId,
            List<DraftLine> requestedLines,
            UUID applicantUserId,
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
        request.setApplicantId(applicantUserId);
        request.setMakerId(makerEmployeeId);
        request.setRemark("生产计划 " + productionPlanNo + " 未覆盖物料自动生成");
        request.setSourceDocNo(productionPlanNo);
        request.setStatus(STATUS_DRAFT);
        requestRepo.save(request);

        List<DraftLineResult> created = new ArrayList<>(lines.size());
        int lineNo = 0;
        for (DraftLine line : lines) {
            lineNo++;
            PurchaseRequestItem item = new PurchaseRequestItem();
            item.setRequestId(request.getId());
            item.setBillNo(request.getBillNo());
            item.setBillDate(request.getBillDate());
            item.setLineNo(lineNo);
            item.setGoodsId(line.goodsId());
            item.setColorId(line.colorId());
            item.setUnitId(line.unitId());
            item.setUnitRate(BigDecimal.ONE);
            item.setQty(line.qty());
            item.setPrice(BigDecimal.ZERO);
            item.setAmountOriginal(BigDecimal.ZERO);
            item.setAmountLocal(BigDecimal.ZERO);
            item.setGiftQty(BigDecimal.ZERO);
            item.setDeliverDate(line.needDate() == null ? needDate : line.needDate());
            item.setProductionPlanNo(productionPlanNo);
            item.setSourceDocNo(productionPlanNo);
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
        return new DraftResult(
                request.getId(), request.getBillNo(), List.copyOf(created));
    }

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
            if (request.getStatus() != STATUS_DRAFT) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "仅草稿采购申请可随计划包取消");
            }
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

    private static LocalDate localDate(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof LocalDate date) {
            return date;
        }
        if (value instanceof java.sql.Date date) {
            return date.toLocalDate();
        }
        throw new ApiException(ErrorCode.CONFLICT, "采购预计日期类型异常");
    }

    private static final class OpenSupplyAccumulator {
        private BigDecimal qty = BigDecimal.ZERO;
        private LocalDate earliest;

        private void add(BigDecimal increment, LocalDate expected) {
            qty = qty.add(increment);
            if (expected != null && (earliest == null || expected.isBefore(earliest))) {
                earliest = expected;
            }
        }

        private OpenSupply toValue() {
            return new OpenSupply(qty, earliest);
        }
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

    public record OpenSupply(BigDecimal openQty, LocalDate earliestDate) {
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
