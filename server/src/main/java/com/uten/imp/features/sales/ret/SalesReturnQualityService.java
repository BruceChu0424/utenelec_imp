package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.ret.dto.ReturnQualityCorrectionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityItemDto;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.UUID;

/**
 * Quality quarantine for customer returns.
 *
 * <p>The quarantine is intentionally outside {@code stock_balances}. A return
 * receipt is therefore traceable but cannot be promised, reserved or picked.
 * Only a controlled {@code GOOD_RELEASE} disposition creates saleable stock.
 */
@Service
@RequiredArgsConstructor
public class SalesReturnQualityService {

    private static final String PENDING = "PENDING";
    private static final String PARTIAL = "PARTIAL";
    private static final String DISPOSED = "DISPOSED";
    private static final String REVERSED = "REVERSED";
    private static final String CORRECT_AUTHORITY = "sales_return_quality:correct";
    private static final String DISPOSE_AUTHORITY = "sales_return_quality:dispose";

    private final EntityManager em;
    private final StockService stockService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final SalesReturnRepository returnRepo;
    private final SalesDocumentAccessPolicy accessPolicy;
    private final com.uten.imp.features.sales.SalesMutationFootprintService mutationFootprint;
    private final com.uten.imp.application.port.SalesReturnInventoryValuePort inventoryValue;

    /** Creates immutable receipt evidence and the mutable quarantine projection. */
    @Transactional(propagation = Propagation.MANDATORY)
    void receive(SalesReturn salesReturn, List<SalesReturnItem> items, OffsetDateTime receivedAt) {
        UUID actor = currentUser.requireEmployeeId();
        for (SalesReturnItem item : items) {
            BigDecimal rate = positiveRate(item.getUnitRate());
            BigDecimal receivedBaseQty = item.getQty().multiply(rate);
            UUID qualityItemId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO sales_return_quality_items (
                        id, return_id, return_item_id, warehouse_id, goods_id,
                        color_id, unit_id, unit_rate, received_base_qty,
                        received_at, updated_at
                    ) VALUES (
                        :id, :returnId, :returnItemId, :warehouseId, :goodsId,
                        :colorId, :unitId, :unitRate, :receivedBaseQty,
                        :receivedAt, :receivedAt
                    )
                    """)
                    .setParameter("id", qualityItemId)
                    .setParameter("returnId", salesReturn.getId())
                    .setParameter("returnItemId", item.getId())
                    .setParameter("warehouseId", salesReturn.getWarehouseId())
                    .setParameter("goodsId", item.getGoodsId())
                    .setParameter("colorId", item.getColorId())
                    .setParameter("unitId", item.getUnitId())
                    .setParameter("unitRate", rate)
                    .setParameter("receivedBaseQty", receivedBaseQty)
                    .setParameter("receivedAt", receivedAt)
                    .executeUpdate();
            appendEvent(UUID.randomUUID(), qualityItemId, "RECEIVED", receivedBaseQty,
                    null, actor, receivedAt);
        }
    }

    /**
     * Reverses only an untouched quarantine receipt. Returns false for a
     * historical approved return, whose original stock posting remains on the
     * legacy reversal path. No historical inspection fact is synthesized.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    boolean reverseUntouchedReceipt(UUID returnId, int expectedItemCount, OffsetDateTime reversedAt) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, received_base_qty, released_base_qty,
                               scrapped_base_qty, rework_base_qty, status
                        FROM sales_return_quality_items
                        WHERE return_id = :returnId
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("returnId", returnId)
                .getResultList();
        if (rows.isEmpty()) return false;
        if (rows.size() != expectedItemCount) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "退货质检冻结台账不完整，禁止红冲并请管理员核查");
        }
        UUID actor = currentUser.requireEmployeeId();
        for (Object[] row : rows) {
            BigDecimal disposed = decimal(row[2]).add(decimal(row[3])).add(decimal(row[4]));
            if (!PENDING.equals(row[5]) || disposed.signum() != 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "退货已发生良品释放、报废或返工处置，不能直接红冲原退货单");
            }
        }
        for (Object[] row : rows) {
            UUID qualityItemId = (UUID) row[0];
            BigDecimal received = decimal(row[1]);
            em.createNativeQuery("""
                    UPDATE sales_return_quality_items
                    SET status = 'REVERSED', updated_at = :reversedAt
                    WHERE id = :id AND status = 'PENDING'
                    """)
                    .setParameter("reversedAt", reversedAt)
                    .setParameter("id", qualityItemId)
                    .executeUpdate();
            appendEvent(UUID.randomUUID(), qualityItemId, "RECEIPT_REVERSED", received,
                    null, actor, reversedAt);
        }
        return true;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_return_quality:view')")
    public List<ReturnQualityItemDto> list(UUID returnId) {
        SalesReturn salesReturn = returnRepo.findById(returnId)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售退货单不存在"));
        // Sales users with view-only authority remain owner-scoped. Quality
        // handlers are a cross-owner warehouse/PMC operation and must be able
        // to read the same quarantine rows they are authorized to dispose.
        accessPolicy.requireReadable(
                salesReturn.getOwnerEmployeeId(),
                "销售退货单不存在",
                CORRECT_AUTHORITY, DISPOSE_AUTHORITY);
        return loadProjection(returnId);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_return_quality:view')"
            + " and hasAuthority('sales_return_quality:dispose')")
    public List<ReturnQualityItemDto> dispose(
            UUID returnId, UUID returnItemId, ReturnQualityDispositionRequest request) {
        tx.bind();
        var sourceGuard = mutationFootprint.beginReturn(returnId);
        SalesReturn salesReturn = returnRepo.findById(returnId)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "销售退货单不存在"));
        // Keep object scope identical to list(): the dedicated handler
        // authority is the only cross-owner bypass.
        accessPolicy.requireWritable(
                salesReturn.getOwnerEmployeeId(),
                "无权处置该销售退货质检冻结",
                DISPOSE_AUTHORITY);
        if (request == null || request.reason() == null
                || request.reason().isBlank()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检处置原因不能为空");
        }
        if (request.reason().length() > 500) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检处置原因不能超过 500 个字符");
        }
        String action = normalizeAction(request.action());
        String reason = request.reason().trim();
        BigDecimal requested = normalizeDispositionQty(request.baseQty());
        String idempotencyKey = normalizeIdempotencyKey(request.idempotencyKey());

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT q.id, q.warehouse_id, q.goods_id, q.color_id,
                               q.unit_id, q.unit_rate, q.received_base_qty,
                               q.released_base_qty, q.scrapped_base_qty,
                               q.rework_base_qty, q.status,
                               i.amount_local, r.status, i.weight
                        FROM sales_return_quality_items q
                        JOIN sales_return_items i ON i.id = q.return_item_id
                        JOIN sales_returns r ON r.id = q.return_id
                        WHERE q.return_id = :returnId
                          AND q.return_item_id = :returnItemId
                          AND COALESCE(r.is_deleted, FALSE) = FALSE
                        FOR UPDATE OF q
                        """)
                .setParameter("returnId", returnId)
                .setParameter("returnItemId", returnItemId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "退货质检冻结明细不存在");
        }
        Object[] row = rows.getFirst();
        if (((Number) row[12]).shortValue() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "仅已审核退货单可执行质检处置");
        }
        UUID qualityItemId = (UUID) row[0];
        UUID eventId = dispositionEventId(qualityItemId, idempotencyKey);
        if (isDispositionReplay(
                eventId, qualityItemId, action, requested, reason)) {
            return loadProjection(returnId);
        }
        sourceGuard.verifyUnchanged();
        String currentStatus = (String) row[10];
        if (!PENDING.equals(currentStatus) && !PARTIAL.equals(currentStatus)) {
            throw new ApiException(ErrorCode.CONFLICT, "该退货质检冻结明细已全部处置或已撤销");
        }

        BigDecimal received = decimal(row[6]);
        BigDecimal released = decimal(row[7]);
        BigDecimal scrapped = decimal(row[8]);
        BigDecimal rework = decimal(row[9]);
        BigDecimal remaining = received.subtract(released).subtract(scrapped).subtract(rework);
        if (requested == null || requested.signum() <= 0 || requested.compareTo(remaining) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "处置数量必须大于 0 且不得超过待质检冻结数量 "
                            + remaining.stripTrailingZeros().toPlainString());
        }

        UUID warehouseId = (UUID) row[1];
        UUID goodsId = (UUID) row[2];
        UUID colorId = (UUID) row[3];
        UUID unitId = (UUID) row[4];
        BigDecimal unitRate = decimal(row[5]);
        OffsetDateTime now = OffsetDateTime.now();
        UUID actor = currentUser.requireEmployeeId();
        BigDecimal releasedWeight=null;

        if ("GOOD_RELEASE".equals(action)) {
            stockService.lockInventory(List.of(new InventoryKey(goodsId, colorId)));
            releasedWeight = proratedIncrementNullable(
                    nullableDecimal(row[13]), received, released, requested);
            released = released.add(requested);
        } else if ("SCRAP".equals(action)) {
            scrapped = scrapped.add(requested);
        } else {
            rework = rework.add(requested);
        }

        BigDecimal totalDisposed = released.add(scrapped).add(rework);
        String nextStatus = totalDisposed.compareTo(received) == 0 ? DISPOSED : PARTIAL;
        int updated = em.createNativeQuery("""
                        UPDATE sales_return_quality_items
                        SET released_base_qty = :released,
                            scrapped_base_qty = :scrapped,
                            rework_base_qty = :rework,
                            status = :status,
                            updated_at = :updatedAt
                        WHERE id = :id
                          AND status IN ('PENDING', 'PARTIAL')
                        """)
                .setParameter("released", released)
                .setParameter("scrapped", scrapped)
                .setParameter("rework", rework)
                .setParameter("status", nextStatus)
                .setParameter("updatedAt", now)
                .setParameter("id", qualityItemId)
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "退货质检冻结状态已变化，请刷新后重试");
        }
        appendEvent(eventId, qualityItemId, action, requested, reason, actor, now);
        if ("GOOD_RELEASE".equals(action)) {
            stockService.recordMovement(new StockService.MovementRequest(
                    now,StockService.TYPE_SALES_RETURN,StockService.SRC_SALES_RETURN,
                    returnId,eventId,goodsId,colorId,warehouseId,StockService.DIR_IN,requested,unitId,unitRate,
                    null,"退货质检良品释放："+reason,releasedWeight,null,
                    new com.uten.imp.application.port.InventoryMovementCostReference.SalesReturnQuality(qualityItemId,eventId)));
        }
        inventoryValue.qualityEventRecorded(eventId,currentUser.requireId());
        return loadProjection(returnId);
    }

    /**
     * 受控纠错（V291 追加式补偿命令）：撤回已登记的某类处置量。
     *
     * <p>撤回 GOOD_RELEASE = 反向出库（该数量退回待处置冻结，须仓库仍有足量未承诺库存）；
     * 撤回 SCRAP/REWORK = 恢复待处置（这些桶本就无库存效果）。事件账追加
     * {@code *_REVOKED}；原事件保留。全量撤回到 0 后明细回到 PENDING，
     * 「未处置才可整单红冲」的门禁语义自然恢复。幂等与处置同一模式但独立键空间。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_return_quality:view')"
            + " and hasAuthority('sales_return_quality:correct')")
    public List<ReturnQualityItemDto> correct(
            UUID returnId, UUID returnItemId, ReturnQualityCorrectionRequest request) {
        tx.bind();
        var sourceGuard = mutationFootprint.beginReturn(returnId);
        SalesReturn salesReturn = returnRepo.findById(returnId)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "销售退货单不存在"));
        accessPolicy.requireWritable(
                salesReturn.getOwnerEmployeeId(),
                "无权纠错该销售退货质检处置",
                CORRECT_AUTHORITY);
        if (request == null || request.reason() == null
                || request.reason().isBlank()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检纠错原因不能为空");
        }
        if (request.reason().length() > 500) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检纠错原因不能超过 500 个字符");
        }
        String action = normalizeAction(request.action());
        String reason = "纠错：" + request.reason().trim();
        BigDecimal requested = normalizeDispositionQty(request.baseQty());
        String idempotencyKey = normalizeIdempotencyKey(request.idempotencyKey());

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT q.id, q.warehouse_id, q.goods_id, q.color_id,
                               q.unit_id, q.unit_rate, q.received_base_qty,
                               q.released_base_qty, q.scrapped_base_qty,
                               q.rework_base_qty, q.status,
                               i.amount_local, r.status, i.weight
                        FROM sales_return_quality_items q
                        JOIN sales_return_items i ON i.id = q.return_item_id
                        JOIN sales_returns r ON r.id = q.return_id
                        WHERE q.return_id = :returnId
                          AND q.return_item_id = :returnItemId
                          AND COALESCE(r.is_deleted, FALSE) = FALSE
                        FOR UPDATE OF q
                        """)
                .setParameter("returnId", returnId)
                .setParameter("returnItemId", returnItemId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "退货质检冻结明细不存在");
        }
        Object[] row = rows.getFirst();
        if (((Number) row[12]).shortValue() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "仅已审核退货单可执行质检纠错");
        }
        UUID qualityItemId = (UUID) row[0];
        UUID eventId = correctionEventId(qualityItemId, idempotencyKey);
        if (isCorrectionReplay(eventId, qualityItemId, action, requested, reason)) {
            return loadProjection(returnId);
        }
        sourceGuard.verifyUnchanged();
        String currentStatus = (String) row[10];
        if (!PARTIAL.equals(currentStatus) && !DISPOSED.equals(currentStatus)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该退货质检冻结明细尚无已登记处置可撤回(当前 "
                            + currentStatus + ")");
        }

        BigDecimal received = decimal(row[6]);
        BigDecimal released = decimal(row[7]);
        BigDecimal scrapped = decimal(row[8]);
        BigDecimal rework = decimal(row[9]);
        BigDecimal bucket = switch (action) {
            case "GOOD_RELEASE" -> released;
            case "SCRAP" -> scrapped;
            default -> rework;
        };
        if (requested.compareTo(bucket) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "撤回数量必须大于 0 且不得超过该类处置已登记数量 "
                            + bucket.stripTrailingZeros().toPlainString());
        }

        UUID warehouseId = (UUID) row[1];
        UUID goodsId = (UUID) row[2];
        UUID colorId = (UUID) row[3];
        UUID unitId = (UUID) row[4];
        BigDecimal unitRate = decimal(row[5]);
        OffsetDateTime now = OffsetDateTime.now();
        UUID actor = currentUser.requireEmployeeId();
        BigDecimal revokedWeight=null;

        if ("GOOD_RELEASE".equals(action)) {
            stockService.lockInventory(List.of(new InventoryKey(goodsId, colorId)));
            requireUnpromisedStock(warehouseId, goodsId, colorId, requested);
            revokedWeight = proratedIncrementNullable(
                    nullableDecimal(row[13]), received,
                    released.subtract(requested), requested);
            released = released.subtract(requested);
        } else if ("SCRAP".equals(action)) {
            scrapped = scrapped.subtract(requested);
        } else {
            rework = rework.subtract(requested);
        }

        BigDecimal totalDisposed = released.add(scrapped).add(rework);
        // 总量守恒：0 ≤ Σ处置 ≤ 收货冻结（撤回不会打穿历史下限，仍显式断言）。
        if (totalDisposed.signum() < 0 || totalDisposed.compareTo(received) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "退货质检处置撤回将破坏数量守恒，禁止执行(请核对台账)");
        }
        String nextStatus = totalDisposed.signum() == 0 ? PENDING : PARTIAL;
        int updated = em.createNativeQuery("""
                        UPDATE sales_return_quality_items
                        SET released_base_qty = :released,
                            scrapped_base_qty = :scrapped,
                            rework_base_qty = :rework,
                            status = :status,
                            updated_at = :updatedAt
                        WHERE id = :id
                          AND status IN ('PARTIAL', 'DISPOSED')
                        """)
                .setParameter("released", released)
                .setParameter("scrapped", scrapped)
                .setParameter("rework", rework)
                .setParameter("status", nextStatus)
                .setParameter("updatedAt", now)
                .setParameter("id", qualityItemId)
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "退货质检冻结状态已变化，请刷新后重试");
        }
        appendEvent(eventId, qualityItemId, action + "_REVOKED", requested, reason, actor, now);
        if ("GOOD_RELEASE".equals(action)) {
            stockService.recordMovement(new StockService.MovementRequest(
                    now,StockService.TYPE_SALES_RETURN,StockService.SRC_SALES_RETURN,
                    returnId,eventId,goodsId,colorId,warehouseId,StockService.DIR_OUT,requested,unitId,unitRate,
                    null,"退货质检良品释放撤回："+reason,revokedWeight,null,
                    new com.uten.imp.application.port.InventoryMovementCostReference.SalesReturnQuality(qualityItemId,eventId)));
        }
        inventoryValue.qualityEventRecorded(eventId,currentUser.requireId());
        return loadProjection(returnId);
    }

    /**
     * 良品释放撤回的库存充分性：该仓余额减本仓与全局生效预留，不得小于撤回量。
     * 已被订单预留（承诺）或已出库的释放量不得凭纠错抽走——那会破坏既有承诺，
     * 须先让单处置预留或走盘点/人工流程。
     */
    private void requireUnpromisedStock(
            UUID warehouseId, UUID goodsId, UUID colorId, BigDecimal quantity) {
        BigDecimal free = decimal(em.createNativeQuery("""
                        SELECT
                          (SELECT COALESCE(SUM(b.qty), 0)
                             FROM stock_balances b
                            WHERE b.warehouse_id = :wid
                              AND b.goods_id = :gid
                              AND (b.color_id IS NOT DISTINCT FROM :cid))
                          -
                          (SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
                             FROM stock_reservations r
                            WHERE COALESCE(r.is_deleted, FALSE) = FALSE
                              AND r.status = 0
                              AND (r.warehouse_id IS NULL OR r.warehouse_id = :wid)
                              AND r.goods_id = :gid
                              AND (r.color_id IS NOT DISTINCT FROM :cid))
                        """)
                .setParameter("wid", warehouseId)
                .setParameter("gid", goodsId)
                .setParameter("cid", colorId)
                .getSingleResult());
        if (free.compareTo(quantity) < 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "撤回的良品释放量在原仓库已被预留或已消耗(可撤回未承诺量 "
                            + free.stripTrailingZeros().toPlainString() + ")，"
                            + "请先释放相关订单预留或走盘点/人工处置");
        }
    }

    private boolean isDispositionReplay(
            UUID eventId, UUID qualityItemId, String action,
            BigDecimal requested, String reason) {
        @SuppressWarnings("unchecked")
        List<Object[]> events = em.createNativeQuery("""
                        SELECT quality_item_id, action, base_qty, reason
                        FROM sales_return_quality_events
                        WHERE id = :eventId
                        """)
                .setParameter("eventId", eventId)
                .getResultList();
        if (events.isEmpty()) {
            return false;
        }
        Object[] existing = events.getFirst();
        if (sameDispositionCommand(
                (UUID) existing[0], (String) existing[1], decimal(existing[2]),
                (String) existing[3], qualityItemId, action, requested, reason)) {
            return true;
        }
        throw new ApiException(
                ErrorCode.CONFLICT,
                "该退货质检幂等键已用于不同处置内容，请刷新后重新操作");
    }

    private boolean isCorrectionReplay(
            UUID eventId, UUID qualityItemId, String action,
            BigDecimal requested, String reason) {
        @SuppressWarnings("unchecked")
        List<Object[]> events = em.createNativeQuery("""
                        SELECT quality_item_id, action, base_qty, reason
                        FROM sales_return_quality_events
                        WHERE id = :eventId
                        """)
                .setParameter("eventId", eventId)
                .getResultList();
        if (events.isEmpty()) {
            return false;
        }
        Object[] existing = events.getFirst();
        if (sameDispositionCommand(
                (UUID) existing[0], (String) existing[1], decimal(existing[2]),
                (String) existing[3], qualityItemId, action + "_REVOKED",
                requested, reason)) {
            return true;
        }
        throw new ApiException(
                ErrorCode.CONFLICT,
                "该退货质检纠错幂等键已用于不同内容，请刷新后重新操作");
    }

    /** 纠错幂等键独立键空间（与处置命令区分，同一键不会串出对方语义）。 */
    static UUID correctionEventId(UUID qualityItemId, String idempotencyKey) {
        String canonical = "SALES_RETURN_QUALITY_CORRECTION|"
                + qualityItemId + "|" + normalizeIdempotencyKey(idempotencyKey);
        return UUID.nameUUIDFromBytes(canonical.getBytes(StandardCharsets.UTF_8));
    }

    private List<ReturnQualityItemDto> loadProjection(UUID returnId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, return_id, return_item_id, warehouse_id,
                               goods_id, color_id, unit_id, unit_rate,
                               received_base_qty, released_base_qty,
                               scrapped_base_qty, rework_base_qty, status,
                               received_at, updated_at
                        FROM sales_return_quality_items
                        WHERE return_id = :returnId
                        ORDER BY received_at, id
                        """)
                .setParameter("returnId", returnId)
                .getResultList();
        return rows.stream().map(row -> {
            BigDecimal received = decimal(row[8]);
            BigDecimal released = decimal(row[9]);
            BigDecimal scrapped = decimal(row[10]);
            BigDecimal rework = decimal(row[11]);
            return new ReturnQualityItemDto(
                    (UUID) row[0], (UUID) row[1], (UUID) row[2], (UUID) row[3],
                    (UUID) row[4], (UUID) row[5], (UUID) row[6], decimal(row[7]),
                    received, released, scrapped, rework,
                    received.subtract(released).subtract(scrapped).subtract(rework),
                    (String) row[12], offsetDateTime(row[13]), offsetDateTime(row[14]));
        }).toList();
    }

    private void appendEvent(UUID eventId, UUID qualityItemId, String action,
                             BigDecimal baseQty, String reason, UUID actor,
                             OffsetDateTime occurredAt) {
        em.createNativeQuery("""
                INSERT INTO sales_return_quality_events (
                    id, quality_item_id, action, base_qty, reason,
                    actor_employee_id, occurred_at
                ) VALUES (
                    :id, :qualityItemId, :action, :baseQty, :reason,
                    :actor, :occurredAt
                )
                """)
                .setParameter("id", eventId)
                .setParameter("qualityItemId", qualityItemId)
                .setParameter("action", action)
                .setParameter("baseQty", baseQty)
                .setParameter("reason", reason)
                .setParameter("actor", actor)
                .setParameter("occurredAt", occurredAt)
                .executeUpdate();
    }

    static String normalizeIdempotencyKey(String key) {
        String normalized = key == null ? "" : key.strip();
        if (normalized.length() < 8 || normalized.length() > 128
                || !normalized.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检幂等键必须为 8 到 128 位字母、数字或 ._:-");
        }
        return normalized;
    }

    static UUID dispositionEventId(UUID qualityItemId, String idempotencyKey) {
        String canonical = "SALES_RETURN_QUALITY_DISPOSITION|"
                + qualityItemId + "|" + normalizeIdempotencyKey(idempotencyKey);
        return UUID.nameUUIDFromBytes(canonical.getBytes(StandardCharsets.UTF_8));
    }

    static boolean sameDispositionCommand(
            UUID storedQualityItemId, String storedAction,
            BigDecimal storedQuantity, String storedReason,
            UUID expectedQualityItemId, String expectedAction,
            BigDecimal expectedQuantity, String expectedReason) {
        return Objects.equals(storedQualityItemId, expectedQualityItemId)
                && Objects.equals(storedAction, expectedAction)
                && storedQuantity.compareTo(expectedQuantity) == 0
                && Objects.equals(storedReason, expectedReason);
    }

    static String normalizeAction(String action) {
        String normalized = action == null ? "" : action.trim().toUpperCase(Locale.ROOT);
        if (!Objects.equals(normalized, "GOOD_RELEASE")
                && !Objects.equals(normalized, "SCRAP")
                && !Objects.equals(normalized, "REWORK")) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "质检处置仅支持 GOOD_RELEASE、SCRAP 或 REWORK");
        }
        return normalized;
    }

    static BigDecimal normalizeDispositionQty(BigDecimal quantity) {
        if (quantity == null || quantity.signum() <= 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检处置数量必须大于 0");
        }
        final BigDecimal normalized;
        try {
            normalized = quantity.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检处置数量最多保留 4 位小数");
        }
        if (normalized.precision() - normalized.scale() > 14) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "退货质检处置数量整数位最多 14 位");
        }
        return normalized;
    }

    /**
     * Uses cumulative rounding so partial releases add up to the exact source
     * amount when the final quantity is released.
     */
    static BigDecimal proratedIncrement(BigDecimal sourceAmount,
                                        BigDecimal receivedBaseQty,
                                        BigDecimal alreadyReleasedBaseQty,
                                        BigDecimal releaseBaseQty) {
        BigDecimal previous = sourceAmount.multiply(alreadyReleasedBaseQty)
                .divide(receivedBaseQty, 4, RoundingMode.HALF_UP);
        BigDecimal next = sourceAmount
                .multiply(alreadyReleasedBaseQty.add(releaseBaseQty))
                .divide(receivedBaseQty, 4, RoundingMode.HALF_UP);
        return next.subtract(previous);
    }

    static BigDecimal proratedIncrementNullable(
            BigDecimal sourceWeight,
            BigDecimal receivedBaseQty,
            BigDecimal alreadyReleasedBaseQty,
            BigDecimal releaseBaseQty) {
        return sourceWeight == null ? null : proratedIncrement(
                sourceWeight, receivedBaseQty,
                alreadyReleasedBaseQty, releaseBaseQty);
    }

    private static BigDecimal nullableDecimal(Object value) {
        return value == null ? null : (BigDecimal) value;
    }

    private static BigDecimal positiveRate(BigDecimal rate) {
        BigDecimal normalized = rate == null ? BigDecimal.ONE : rate;
        if (normalized.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "退货明细单位换算率必须大于 0");
        }
        return normalized;
    }

    static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        throw new ApiException(
                ErrorCode.CONFLICT,
                "退货质检时间字段类型异常");
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }
}
