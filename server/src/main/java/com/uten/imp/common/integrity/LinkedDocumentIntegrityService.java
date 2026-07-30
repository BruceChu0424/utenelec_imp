package com.uten.imp.common.integrity;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeSet;
import java.util.UUID;
import java.util.function.Function;

/**
 * Locks and validates polymorphic source-document links before an approval
 * posts stock or finance effects.
 *
 * <p>The UUID links intentionally have no cross-module foreign keys. This
 * component is therefore the authoritative runtime boundary: a caller cannot
 * attach a valid UUID from another supplier, document state, or goods line.
 */
@Component
@RequiredArgsConstructor
public class LinkedDocumentIntegrityService {

    private static final short STATUS_APPROVED = 1;

    private final EntityManager em;

    /**
     * A normalized linked line used by purchase and subcontract approval
     * services. Fields that do not apply to a document type may be null.
     */
    public record LinkedLine(
            UUID sourceItemId,
            UUID orderItemId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            UUID parentGoodsId,
            UUID parentColorId) {

        public static LinkedLine orderSource(
                UUID orderItemId, UUID goodsId, UUID colorId, UUID unitId) {
            return new LinkedLine(
                    orderItemId, orderItemId, goodsId, colorId, unitId, null, null);
        }

        public static LinkedLine receiptSource(
                UUID receiptItemId,
                UUID orderItemId,
                UUID goodsId,
                UUID colorId,
                UUID unitId) {
            return new LinkedLine(
                    receiptItemId, orderItemId, goodsId, colorId, unitId, null, null);
        }

        public static LinkedLine materialIssueSource(
                UUID issueItemId,
                UUID orderItemId,
                UUID goodsId,
                UUID colorId,
                UUID unitId,
                UUID parentGoodsId,
                UUID parentColorId) {
            return new LinkedLine(
                    issueItemId,
                    orderItemId,
                    goodsId,
                    colorId,
                    unitId,
                    parentGoodsId,
                    parentColorId);
        }
    }

    /** Upstream request/application allocation made by an order line. */
    public record QuantityLinkedLine(
            UUID sourceItemId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal qty) {}

    @Transactional(propagation = Propagation.MANDATORY)
    public void validatePurchaseOrder(List<QuantityLinkedLine> lines) {
        Map<UUID, Object[]> rows = lockRows(
                lines, QuantityLinkedLine::sourceItemId, """
                        SELECT ri.id, ri.goods_id, ri.color_id, ri.unit_id,
                               ri.qty, COALESCE(ri.ordered_qty, 0), r.status,
                               COALESCE(r.is_stopped, FALSE)
                        FROM purchase_request_items ri
                        JOIN purchase_requests r ON r.id = ri.request_id
                        WHERE ri.id IN (:ids)
                          AND COALESCE(ri.is_deleted, FALSE) = FALSE
                          AND COALESCE(r.is_deleted, FALSE) = FALSE
                        ORDER BY ri.id
                        FOR UPDATE OF ri, r
                        """);
        validateUpstreamAllocations(lines, rows);
    }

    /**
     * Locks the request/application counters before an approved order removes
     * its allocation. Reversal deliberately does not re-run approval rules:
     * a source may since have been closed, stopped, or contain legacy
     * over-allocation, but its counter still has to be decremented atomically.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockPurchaseRequestItemsForReversal(Collection<UUID> sourceItemIds) {
        lockIds(sourceItemIds, """
                SELECT ri.id
                FROM purchase_request_items ri
                JOIN purchase_requests r ON r.id = ri.request_id
                WHERE ri.id IN (:ids)
                ORDER BY ri.id
                FOR UPDATE OF ri, r
                """, "采购来源申请明细不存在");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void lockSubcontractApplicationItemsForReversal(
            Collection<UUID> sourceItemIds) {
        lockIds(sourceItemIds, """
                SELECT ai.id
                FROM subcontract_application_items ai
                JOIN subcontract_applications a ON a.id = ai.application_id
                WHERE ai.id IN (:ids)
                ORDER BY ai.id
                FOR UPDATE OF ai, a
                """, "委外来源申请明细不存在");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void validateSubcontractOrder(
            UUID supplierId, List<QuantityLinkedLine> lines) {
        requireParty(supplierId, "委外订货单需指定委外商");
        Map<UUID, Object[]> rows = lockRows(
                lines, QuantityLinkedLine::sourceItemId, """
                        SELECT ai.id, a.supplier_id, ai.goods_id, ai.color_id,
                               ai.unit_id, ai.qty, COALESCE(ai.ordered_qty, 0),
                               a.status
                        FROM subcontract_application_items ai
                        JOIN subcontract_applications a ON a.id = ai.application_id
                        WHERE ai.id IN (:ids)
                          AND COALESCE(ai.is_deleted, FALSE) = FALSE
                          AND COALESCE(a.is_deleted, FALSE) = FALSE
                        ORDER BY ai.id
                        FOR UPDATE OF ai, a
                        """);
        for (QuantityLinkedLine line : lines) {
            if (line.sourceItemId() == null) {
                continue;
            }
            Object[] source = requireSource(
                    rows, line.sourceItemId(), "委外来源申请明细不存在或已删除");
            requireApproved(source[7], "委外订货只能关联已审核申请单");
            requireSame(supplierId, uuid(source[1]), "委外商与来源申请单不一致");
            requireQuantityDimensions(line, source, 2, "委外订货明细与来源申请明细不一致");
        }
        validateAllocationCapacity(lines, rows, 5, 6, "委外订货量超过申请剩余量");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void validatePurchaseReceipt(UUID supplierId, List<LinkedLine> lines) {
        requireParty(supplierId, "采购收货单需指定供应商");
        validatePurchaseOrderSources(supplierId, lines, LinkedLine::sourceItemId);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void validatePurchaseReturn(UUID supplierId, List<LinkedLine> lines) {
        requireParty(supplierId, "采购退货单需指定供应商");
        Map<UUID, Object[]> receiptRows = lockRows(
                lines, LinkedLine::sourceItemId, """
                        SELECT ri.id, r.supplier_id, ri.goods_id, ri.color_id,
                               ri.unit_id, ri.order_item_id, r.status
                        FROM purchase_receipt_items ri
                        JOIN purchase_receipts r ON r.id = ri.receipt_id
                        WHERE ri.id IN (:ids)
                          AND COALESCE(ri.is_deleted, FALSE) = FALSE
                          AND COALESCE(r.is_deleted, FALSE) = FALSE
                        ORDER BY ri.id
                        FOR UPDATE OF ri, r
                        """);
        for (LinkedLine line : lines) {
            if (line.sourceItemId() == null) {
                continue;
            }
            Object[] source = requireSource(
                    receiptRows, line.sourceItemId(), "采购退货关联的收货明细不存在或已删除");
            requireApproved(source[6], "采购退货只能关联已审核收货单");
            requireSame(supplierId, uuid(source[1]), "采购退货供应商与来源收货单不一致");
            requireDimensions(line, source, 2, "采购退货明细与来源收货明细不一致");
            requireSame(
                    line.orderItemId(),
                    uuid(source[5]),
                    "采购退货的订货来源与收货来源链不一致");
        }
        validatePurchaseOrderSources(supplierId, lines, LinkedLine::orderItemId);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void validateSubcontractReceipt(UUID supplierId, List<LinkedLine> lines) {
        requireParty(supplierId, "委外进仓单需指定委外商");
        validateSubcontractOrderSources(
                supplierId, lines, LinkedLine::sourceItemId, true);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void validateSubcontractReturn(UUID supplierId, List<LinkedLine> lines) {
        requireParty(supplierId, "委外退货单需指定委外商");
        Map<UUID, Object[]> receiptRows = lockRows(
                lines, LinkedLine::sourceItemId, """
                        SELECT ri.id, r.supplier_id, ri.goods_id, ri.color_id,
                               ri.unit_id, ri.order_item_id, r.status
                        FROM subcontract_receipt_items ri
                        JOIN subcontract_receipts r ON r.id = ri.receipt_id
                        WHERE ri.id IN (:ids)
                          AND COALESCE(ri.is_deleted, FALSE) = FALSE
                          AND COALESCE(r.is_deleted, FALSE) = FALSE
                        ORDER BY ri.id
                        FOR UPDATE OF ri, r
                        """);
        for (LinkedLine line : lines) {
            if (line.sourceItemId() == null) {
                continue;
            }
            Object[] source = requireSource(
                    receiptRows, line.sourceItemId(), "委外退货来源进仓明细不存在或已删除");
            requireApproved(source[6], "委外退货只能关联已审核进仓单");
            requireSame(supplierId, uuid(source[1]), "委外退货的委外商与来源进仓单不一致");
            requireDimensions(line, source, 2, "委外退货明细与来源进仓明细不一致");
            requireSame(
                    line.orderItemId(),
                    uuid(source[5]),
                    "委外退货的订货来源与进仓来源链不一致");
        }
        validateSubcontractOrderSources(
                supplierId, lines, LinkedLine::orderItemId, true);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void validateSubcontractMaterialReturn(
            UUID supplierId, List<LinkedLine> lines) {
        validateSubcontractMaterialDisposition(supplierId, lines, true);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void validateSubcontractWaste(
            UUID supplierId, List<LinkedLine> lines) {
        validateSubcontractMaterialDisposition(supplierId, lines, false);
    }

    private void validateSubcontractMaterialDisposition(
            UUID supplierId,
            List<LinkedLine> lines,
            boolean requireReturnChainFields) {
        requireParty(supplierId, "委外材料单需指定委外商");
        Map<UUID, Object[]> issueRows = lockRows(
                lines, LinkedLine::sourceItemId, """
                        SELECT ii.id, i.supplier_id, ii.goods_id, ii.color_id,
                               ii.unit_id, ii.order_item_id, ii.parent_goods_id,
                               ii.parent_color_id, i.status
                        FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_issues i ON i.id = ii.issue_id
                        WHERE ii.id IN (:ids)
                          AND COALESCE(ii.is_deleted, FALSE) = FALSE
                          AND COALESCE(i.is_deleted, FALSE) = FALSE
                        ORDER BY ii.id
                        FOR UPDATE OF ii, i
                        """);
        for (LinkedLine line : lines) {
            if (line.sourceItemId() == null) {
                continue;
            }
            Object[] source = requireSource(
                    issueRows, line.sourceItemId(), "委外材料来源发料明细不存在或已删除");
            requireApproved(source[8], "委外退料/损耗只能关联已审核发料单");
            requireSame(supplierId, uuid(source[1]), "委外商与来源发料单不一致");
            requireDimensions(line, source, 2, "委外材料明细与来源发料明细不一致");
            if (requireReturnChainFields) {
                requireSame(
                        line.orderItemId(),
                        uuid(source[5]),
                        "委外材料明细的订货来源与发料来源链不一致");
                requireSame(
                        line.parentGoodsId(),
                        uuid(source[6]),
                        "委外材料明细的父件货品与来源发料明细不一致");
                requireSame(
                        line.parentColorId(),
                        uuid(source[7]),
                        "委外材料明细的父件颜色与来源发料明细不一致");
            }
        }

        // Validate the second hop whenever a material issue was linked to an
        // order. It prevents a valid issue UUID from being paired with an
        // unrelated or reversed subcontract order.
        List<LinkedLine> orderLines = lines.stream()
                .map(line -> {
                    if (line.sourceItemId() == null) {
                        return line;
                    }
                    Object[] source = issueRows.get(line.sourceItemId());
                    UUID orderItemId = source == null ? null : uuid(source[5]);
                    return new LinkedLine(
                            line.sourceItemId(),
                            orderItemId,
                            uuid(source == null ? null : source[6]),
                            uuid(source == null ? null : source[7]),
                            null,
                            null,
                            null);
                })
                .toList();
        validateSubcontractOrderSources(
                supplierId, orderLines, LinkedLine::orderItemId, false);
    }

    private void validatePurchaseOrderSources(
            UUID supplierId,
            List<LinkedLine> lines,
            Function<LinkedLine, UUID> sourceId) {
        Map<UUID, Object[]> rows = lockRows(lines, sourceId, """
                SELECT oi.id, o.supplier_id, oi.goods_id, oi.color_id,
                       oi.unit_id, o.status, COALESCE(o.is_stopped, FALSE)
                FROM purchase_order_items oi
                JOIN purchase_orders o ON o.id = oi.order_id
                WHERE oi.id IN (:ids)
                  AND COALESCE(oi.is_deleted, FALSE) = FALSE
                  AND COALESCE(o.is_deleted, FALSE) = FALSE
                ORDER BY oi.id
                FOR UPDATE OF oi, o
                """);
        for (LinkedLine line : lines) {
            UUID id = sourceId.apply(line);
            if (id == null) {
                continue;
            }
            Object[] source = requireSource(
                    rows, id, "采购来源订货明细不存在或已删除");
            requireApproved(source[5], "采购收货/退货只能关联已审核订货单");
            if (Boolean.TRUE.equals(source[6])) {
                throw business("采购来源订货单已中止");
            }
            requireSame(supplierId, uuid(source[1]), "供应商与来源订货单不一致");
            requireDimensions(line, source, 2, "采购明细与来源订货明细不一致");
        }
    }

    private void validateUpstreamAllocations(
            List<QuantityLinkedLine> lines,
            Map<UUID, Object[]> rows) {
        for (QuantityLinkedLine line : lines) {
            requirePositiveQuantity(line.qty());
            if (line.sourceItemId() == null) {
                continue;
            }
            Object[] source = requireSource(
                    rows, line.sourceItemId(), "采购来源申请明细不存在或已删除");
            requireApproved(source[6], "采购订货只能关联已审核申请单");
            if (Boolean.TRUE.equals(source[7])) {
                throw business("采购来源申请单已中止");
            }
            requireQuantityDimensions(line, source, 1, "采购订货明细与来源申请明细不一致");
        }
        validateAllocationCapacity(lines, rows, 4, 5, "采购订货量超过申请剩余量");
    }

    private void validateAllocationCapacity(
            List<QuantityLinkedLine> lines,
            Map<UUID, Object[]> rows,
            int capacityIndex,
            int allocatedIndex,
            String message) {
        Map<UUID, BigDecimal> increments = new HashMap<>();
        for (QuantityLinkedLine line : lines) {
            requirePositiveQuantity(line.qty());
            if (line.sourceItemId() != null) {
                increments.merge(line.sourceItemId(), line.qty(), BigDecimal::add);
            }
        }
        for (Map.Entry<UUID, BigDecimal> entry : increments.entrySet()) {
            Object[] source = requireSource(rows, entry.getKey(), message);
            BigDecimal capacity = decimal(source[capacityIndex]);
            BigDecimal allocated = decimal(source[allocatedIndex]);
            if (allocated.add(entry.getValue()).compareTo(capacity) > 0) {
                throw business(message);
            }
        }
    }

    private void validateSubcontractOrderSources(
            UUID supplierId,
            List<LinkedLine> lines,
            Function<LinkedLine, UUID> sourceId,
            boolean compareUnit) {
        Map<UUID, Object[]> rows = lockRows(lines, sourceId, """
                SELECT oi.id, o.supplier_id, oi.goods_id, oi.color_id,
                       oi.unit_id, o.status
                FROM subcontract_order_items oi
                JOIN subcontract_orders o ON o.id = oi.order_id
                WHERE oi.id IN (:ids)
                  AND COALESCE(oi.is_deleted, FALSE) = FALSE
                  AND COALESCE(o.is_deleted, FALSE) = FALSE
                ORDER BY oi.id
                FOR UPDATE OF oi, o
                """);
        for (LinkedLine line : lines) {
            UUID id = sourceId.apply(line);
            if (id == null) {
                continue;
            }
            Object[] source = requireSource(
                    rows, id, "委外来源订货明细不存在或已删除");
            requireApproved(source[5], "委外业务只能关联已审核订货单");
            requireSame(supplierId, uuid(source[1]), "委外商与来源订货单不一致");
            if (!Objects.equals(line.goodsId(), uuid(source[2]))
                    || !Objects.equals(line.colorId(), uuid(source[3]))
                    || (compareUnit
                        && !Objects.equals(line.unitId(), uuid(source[4])))) {
                throw business("委外成品与来源订货明细不一致");
            }
        }
    }

    private <T> Map<UUID, Object[]> lockRows(
            List<T> lines,
            Function<T, UUID> sourceId,
            String sql) {
        Collection<UUID> ids = new TreeSet<>();
        for (T line : lines) {
            UUID id = sourceId.apply(line);
            if (id != null) {
                ids.add(id);
            }
        }
        if (ids.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery(sql).setParameter("ids", ids));
        Map<UUID, Object[]> byId = new HashMap<>();
        for (Object[] row : rows) {
            byId.put(uuid(row[0]), row);
        }
        return byId;
    }

    private void lockIds(
            Collection<UUID> requestedIds,
            String sql,
            String missingMessage) {
        TreeSet<UUID> ids = new TreeSet<>();
        if (requestedIds != null) {
            requestedIds.stream().filter(Objects::nonNull).forEach(ids::add);
        }
        if (ids.isEmpty()) {
            return;
        }
        List<?> locked = em.createNativeQuery(sql)
                .setParameter("ids", ids)
                .getResultList();
        if (locked.size() != ids.size()) {
            throw business(missingMessage);
        }
    }

    private static Object[] requireSource(
            Map<UUID, Object[]> sources, UUID id, String message) {
        Object[] source = sources.get(id);
        if (source == null) {
            throw business(message);
        }
        return source;
    }

    private static void requireApproved(Object rawStatus, String message) {
        if (!(rawStatus instanceof Number status)
                || status.shortValue() != STATUS_APPROVED) {
            throw business(message);
        }
    }

    private static void requireDimensions(
            LinkedLine line, Object[] source, int firstDimension, String message) {
        if (!Objects.equals(line.goodsId(), uuid(source[firstDimension]))
                || !Objects.equals(line.colorId(), uuid(source[firstDimension + 1]))
                || !Objects.equals(line.unitId(), uuid(source[firstDimension + 2]))) {
            throw business(message);
        }
    }

    private static void requireQuantityDimensions(
            QuantityLinkedLine line,
            Object[] source,
            int firstDimension,
            String message) {
        if (!Objects.equals(line.goodsId(), uuid(source[firstDimension]))
                || !Objects.equals(line.colorId(), uuid(source[firstDimension + 1]))
                || !Objects.equals(line.unitId(), uuid(source[firstDimension + 2]))) {
            throw business(message);
        }
    }

    private static void requirePositiveQuantity(BigDecimal qty) {
        if (qty == null || qty.signum() <= 0) {
            throw business("订货数量必须大于 0");
        }
    }

    private static void requireParty(UUID partyId, String message) {
        if (partyId == null) {
            throw business(message);
        }
    }

    private static void requireSame(Object actual, Object expected, String message) {
        if (!Objects.equals(actual, expected)) {
            throw business(message);
        }
    }

    private static UUID uuid(Object value) {
        return value == null ? null : (UUID) value;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static ApiException business(String message) {
        return new ApiException(ErrorCode.BUSINESS, message);
    }
}
