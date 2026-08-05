package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.UUID;

/**
 * 采购/委外收货 IQC 待检隔离（V222，镜像 V189 销售退货质检冻结的 sidecar 模式）。
 *
 * <p>收货审核调用 {@link #receive} 把每条收货明细写入 {@code procurement_inspection_items}
 * （PENDING，<b>不写 stock_balances</b>）。因此三个可用量口径（warehouseAvailableBase /
 * globalAvailableBase / v_stock_available）自然不含待检品——零改动、零口径漂移，这是比
 * "给 stock_balances 加 inspection_status 列"更稳的选型（详见 ADR）。
 *
 * <p>只有受控的 {@code PASS} 处置才 {@link StockService#recordMovement} {@code DIR_IN}
 * 进可用库存，并在整单质检结案后唤醒生产（WAITING→READY）。{@code FAIL} 只记质量事实，不入可用。
 * 收货红冲前须所有明细已结案（RESOLVED），由 {@link #reverseResolvedStock} 反向已放行库存。
 */
@Service
@RequiredArgsConstructor
public class ProcurementInspectionService implements ProcurementInspectionPort {

    private static final String PENDING = "PENDING";
    private static final String PARTIAL = "PARTIAL";
    private static final String RESOLVED = "RESOLVED";
    private static final String REVERSED = "REVERSED";
    private static final String HANDLE_AUTHORITY = "procurement_inspection:handle";

    private final EntityManager em;
    private final StockService stockService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionSupplyTransitionPort purchaseSupply;
    private final ProductionSubcontractSupplyTransitionPort subcontractSupply;

    /** 收货审核同事务调用：建冻结行 + RECEIVED 事件；不写 stock_balances。 */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void receive(String receiptType, UUID receiptId, UUID warehouseId,
                        List<ProcurementInspectionPort.ReceivedLine> lines, OffsetDateTime receivedAt) {
        UUID actor = currentUser.requireEmployeeId();
        for (ReceivedLine l : lines) {
            BigDecimal rate = positiveRate(l.unitRate());
            BigDecimal receivedBase = l.qty().multiply(rate);
            BigDecimal amount = l.amountLocal() == null ? BigDecimal.ZERO : l.amountLocal();
            UUID inspectionItemId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO procurement_inspection_items (
                        id, receipt_type, receipt_id, receipt_item_id, warehouse_id, goods_id,
                        color_id, unit_id, unit_rate, received_base_qty, received_amount_local, received_at
                    ) VALUES (
                        :id, :receiptType, :receiptId, :receiptItemId, :warehouseId, :goodsId,
                        :colorId, :unitId, :unitRate, :receivedBase, :amount, :receivedAt
                    )
                    """)
                    .setParameter("id", inspectionItemId)
                    .setParameter("receiptType", receiptType)
                    .setParameter("receiptId", receiptId)
                    .setParameter("receiptItemId", l.receiptItemId())
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("goodsId", l.goodsId())
                    .setParameter("colorId", l.colorId())
                    .setParameter("unitId", l.unitId())
                    .setParameter("unitRate", rate)
                    .setParameter("receivedBase", receivedBase)
                    .setParameter("amount", amount)
                    .setParameter("receivedAt", receivedAt)
                    .executeUpdate();
            appendEvent(UUID.randomUUID(), inspectionItemId, "RECEIVED", receivedBase, null, actor, receivedAt);
        }
    }

    /**
     * 受控质检结论：{@code PASS} 放行进可用库存（DIR_IN）+ 整单结案后唤醒生产；
     * {@code FAIL} 只记质量事实，不入可用。事件账幂等（同键同命令静默重放，同键异命令 409）。
     */
    @Transactional
    @PreAuthorize("hasAuthority('procurement_inspection:view')"
            + " and hasAuthority('procurement_inspection:handle')")
    public void dispose(String receiptType, UUID receiptId, UUID inspectionItemId,
                        InspectionDispositionRequest request) {
        tx.bind();
        if (request == null || request.reason() == null || request.reason().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "质检结论原因不能为空");
        }
        if (request.reason().length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "质检结论原因不能超过 500 个字符");
        }
        String action = normalizeAction(request.action());
        String reason = request.reason().trim();
        BigDecimal requested = normalizeQty(request.baseQty());
        String idempotencyKey = normalizeIdempotencyKey(request.idempotencyKey());

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, warehouse_id, goods_id, color_id, unit_id, unit_rate,
                               received_base_qty, received_amount_local,
                               passed_base_qty, failed_base_qty, status, receipt_type
                        FROM procurement_inspection_items
                        WHERE id = :id AND receipt_type = :rt AND receipt_id = :rid
                        FOR UPDATE
                        """)
                .setParameter("id", inspectionItemId)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "待检明细不存在");
        }
        Object[] row = rows.getFirst();
        if (!Objects.equals(receiptType, row[11])) {
            throw new ApiException(ErrorCode.CONFLICT, "质检结论的单据类型不一致");
        }
        UUID eventId = dispositionEventId(inspectionItemId, idempotencyKey);
        if (isReplay(eventId, inspectionItemId, action, requested, reason)) return;

        String currentStatus = (String) row[10];
        if (!PENDING.equals(currentStatus) && !PARTIAL.equals(currentStatus)) {
            throw new ApiException(ErrorCode.CONFLICT, "该待检明细已全部结案或已撤销");
        }
        BigDecimal received = dec(row[6]);
        BigDecimal passed = dec(row[8]);
        BigDecimal failed = dec(row[9]);
        BigDecimal remaining = received.subtract(passed).subtract(failed);
        if (requested.signum() <= 0 || requested.compareTo(remaining) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "质检数量必须大于 0 且不得超过待检数量 " + remaining.stripTrailingZeros().toPlainString());
        }

        OffsetDateTime now = OffsetDateTime.now();
        UUID actor = currentUser.requireEmployeeId();
        UUID warehouseId = (UUID) row[1];
        UUID goodsId = (UUID) row[2];
        UUID colorId = (UUID) row[3];
        UUID unitId = (UUID) row[4];
        BigDecimal unitRate = dec(row[5]);
        BigDecimal receivedAmount = dec(row[7]);

        if ("PASS".equals(action)) {
            stockService.lockInventory(List.of(new InventoryKey(goodsId, colorId)));
            BigDecimal passedAmount = proratedIncrement(receivedAmount, received, passed, requested);
            stockService.recordMovement(new StockService.MovementRequest(
                    now, movementType(receiptType), sourceDocType(receiptType),
                    receiptId, inspectionItemId, goodsId, colorId, warehouseId,
                    StockService.DIR_IN, requested, unitId, unitRate, passedAmount,
                    "IQC 合格放行：" + reason));
            passed = passed.add(requested);
        } else {
            failed = failed.add(requested);
        }

        BigDecimal resolved = passed.add(failed);
        String nextStatus = resolved.compareTo(received) == 0 ? RESOLVED : PARTIAL;
        int updated = em.createNativeQuery("""
                        UPDATE procurement_inspection_items
                        SET passed_base_qty = :passed,
                            failed_base_qty = :failed,
                            status = :status,
                            passed_at = CASE WHEN :passed > 0 THEN :now ELSE passed_at END,
                            updated_at = :now
                        WHERE id = :id AND status IN ('PENDING', 'PARTIAL')
                        """)
                .setParameter("passed", passed)
                .setParameter("failed", failed)
                .setParameter("status", nextStatus)
                .setParameter("now", now)
                .setParameter("id", inspectionItemId)
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "待检状态已变化，请刷新后重试");
        }
        appendEvent(eventId, inspectionItemId, action, requested, reason, actor, now);

        // 整单质检结案后唤醒生产一次（WAITING→READY）；已唤醒则幂等跳过。
        if (allResolved(receiptType, receiptId) && !alreadyWoken(receiptType, receiptId)) {
            wakeProduction(receiptType, receiptId);
            appendReceiptEvent(receiptType, receiptId, "PRODUCTION_WOKEN", BigDecimal.ZERO,
                    "整单质检结案，唤醒生产供给", actor, now);
        }
    }

    /** 收货红冲前置校验：存在待检行时，必须全部结案（RESOLVED）才能红冲。 */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireResolvedForReverse(String receiptType, UUID receiptId) {
        Integer pending = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid
                          AND status IN ('PENDING', 'PARTIAL')
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getSingleResult()).intValue();
        if (pending > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "收货单尚有未完成质检结论的明细，请先质检结案再红冲");
        }
    }

    /**
     * 收货红冲同事务调用：反向已 PASS 放行的库存（仅 passed 量），并置冻结行 REVERSED。
     * 返回是否管理了该单（有冻结行）；无冻结行时调用方走历史全量反向。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean reverseResolvedStock(String receiptType, UUID receiptId, OffsetDateTime now) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, warehouse_id, goods_id, color_id, unit_id, unit_rate,
                               passed_base_qty, received_amount_local, received_base_qty, status
                        FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getResultList();
        if (rows.isEmpty()) return false;
        UUID actor = currentUser.requireEmployeeId();
        for (Object[] row : rows) {
            UUID inspectionItemId = (UUID) row[0];
            BigDecimal passed = dec(row[6]);
            if (passed.signum() > 0) {
                BigDecimal passedAmount = dec(row[7]);
                BigDecimal receivedBase = dec(row[8]);
                // 反向放行金额 = 已放行金额（一次性反向整条已放行量）。
                stockService.recordMovement(new StockService.MovementRequest(
                        now, movementType(receiptType), sourceDocType(receiptType),
                        receiptId, inspectionItemId, (UUID) row[2], (UUID) row[3], (UUID) row[1],
                        StockService.DIR_OUT, passed, (UUID) row[4], dec(row[5]), passedAmount,
                        "红冲收货，反向 IQC 已放行库存"));
            }
            em.createNativeQuery("""
                    UPDATE procurement_inspection_items
                    SET status = 'REVERSED', updated_at = :now
                    WHERE id = :id AND status = 'RESOLVED'
                    """)
                    .setParameter("now", now)
                    .setParameter("id", inspectionItemId)
                    .executeUpdate();
            appendEvent(UUID.randomUUID(), inspectionItemId, "RECEIPT_REVERSED", passed, null, actor, now);
        }
        return true;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    @SuppressWarnings("unchecked")
    public List<Object[]> pendingForReceipt(String receiptType, UUID receiptId) {
        return em.createNativeQuery("""
                        SELECT id, receipt_item_id, goods_id, color_id, unit_id, unit_rate,
                               received_base_qty, passed_base_qty, failed_base_qty, status
                        FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid
                        ORDER BY received_at, id
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getResultList();
    }

    // ---- helpers ----

    private boolean allResolved(String receiptType, UUID receiptId) {
        Integer unfinished = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid
                          AND status <> 'RESOLVED'
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getSingleResult()).intValue();
        // 有冻结行且全部 RESOLVED 才算结案。
        Integer total = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getSingleResult()).intValue();
        return total > 0 && unfinished == 0;
    }

    private boolean alreadyWoken(String receiptType, UUID receiptId) {
        Integer woken = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM procurement_inspection_events e
                        JOIN procurement_inspection_items i ON i.id = e.inspection_item_id
                        WHERE e.action = 'PRODUCTION_WOKEN'
                          AND i.receipt_type = :rt AND i.receipt_id = :rid
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getSingleResult()).intValue();
        return woken > 0;
    }

    private void wakeProduction(String receiptType, UUID receiptId) {
        if (PURCHASE.equals(receiptType)) {
            purchaseSupply.onPurchaseReceiptApproved(receiptId);
        } else {
            subcontractSupply.onSubcontractReceiptApproved(receiptId);
        }
    }

    private boolean isReplay(UUID eventId, UUID inspectionItemId, String action,
                             BigDecimal requested, String reason) {
        @SuppressWarnings("unchecked")
        List<Object[]> events = em.createNativeQuery("""
                        SELECT inspection_item_id, action, base_qty, reason
                        FROM procurement_inspection_events WHERE id = :id
                        """)
                .setParameter("id", eventId)
                .getResultList();
        if (events.isEmpty()) return false;
        Object[] ex = events.getFirst();
        if (Objects.equals(ex[0], inspectionItemId)
                && Objects.equals(ex[1], action)
                && dec(ex[2]).compareTo(requested) == 0
                && Objects.equals(ex[3], reason)) {
            return true;
        }
        throw new ApiException(ErrorCode.CONFLICT, "该质检幂等键已用于不同结论，请刷新后重新操作");
    }

    private void appendEvent(UUID eventId, UUID inspectionItemId, String action,
                             BigDecimal baseQty, String reason, UUID actor, OffsetDateTime occurredAt) {
        em.createNativeQuery("""
                INSERT INTO procurement_inspection_events (
                    id, inspection_item_id, action, base_qty, reason, actor_employee_id, occurred_at
                ) VALUES (:id, :iid, :action, :qty, :reason, :actor, :at)
                """)
                .setParameter("id", eventId)
                .setParameter("iid", inspectionItemId)
                .setParameter("action", action)
                .setParameter("qty", baseQty)
                .setParameter("reason", reason)
                .setParameter("actor", actor)
                .setParameter("at", occurredAt)
                .executeUpdate();
    }

    /** PRODUCTION_WOKEN 以单据维度去重：挂在任一明细事件上（取第一条），按 receipt 查重。 */
    private void appendReceiptEvent(String receiptType, UUID receiptId, String action,
                                    BigDecimal qty, String reason, UUID actor, OffsetDateTime at) {
        UUID anyItem = (UUID) em.createNativeQuery("""
                        SELECT id FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid ORDER BY id LIMIT 1
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getSingleResult();
        appendEvent(UUID.randomUUID(), anyItem, action, qty, reason, actor, at);
    }

    private short movementType(String receiptType) {
        return ProcurementInspectionPort.PURCHASE.equals(receiptType)
                ? StockService.TYPE_PURCHASE_RECEIPT
                : StockService.TYPE_SUBCONTRACT_RECEIPT;
    }

    private String sourceDocType(String receiptType) {
        return ProcurementInspectionPort.PURCHASE.equals(receiptType)
                ? StockService.SRC_PURCHASE_RECEIPT
                : StockService.SRC_SUBCONTRACT_RECEIPT;
    }

    static BigDecimal proratedIncrement(BigDecimal sourceAmount, BigDecimal receivedBase,
                                        BigDecimal alreadyPassed, BigDecimal passBase) {
        BigDecimal previous = sourceAmount.multiply(alreadyPassed)
                .divide(receivedBase, 4, RoundingMode.HALF_UP);
        BigDecimal next = sourceAmount.multiply(alreadyPassed.add(passBase))
                .divide(receivedBase, 4, RoundingMode.HALF_UP);
        return next.subtract(previous);
    }

    static String normalizeAction(String action) {
        String n = action == null ? "" : action.trim().toUpperCase(Locale.ROOT);
        if (!"PASS".equals(n) && !"FAIL".equals(n)) {
            throw new ApiException(ErrorCode.BUSINESS, "质检结论仅支持 PASS 或 FAIL");
        }
        return n;
    }

    static BigDecimal normalizeQty(BigDecimal qty) {
        if (qty == null || qty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "质检数量必须大于 0");
        }
        try {
            return qty.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "质检数量最多保留 4 位小数");
        }
    }

    static String normalizeIdempotencyKey(String key) {
        String n = key == null ? "" : key.strip();
        if (n.length() < 8 || n.length() > 128 || !n.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "质检幂等键必须为 8 到 128 位字母、数字或 ._:-");
        }
        return n;
    }

    static UUID dispositionEventId(UUID inspectionItemId, String idempotencyKey) {
        String canonical = "PROCUREMENT_INSPECTION|" + inspectionItemId
                + "|" + normalizeIdempotencyKey(idempotencyKey);
        return UUID.nameUUIDFromBytes(canonical.getBytes(StandardCharsets.UTF_8));
    }

    private static BigDecimal positiveRate(BigDecimal rate) {
        BigDecimal n = rate == null ? BigDecimal.ONE : rate;
        if (n.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "收货明细单位换算率必须大于 0");
        }
        return n;
    }

    private static BigDecimal dec(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }
}
