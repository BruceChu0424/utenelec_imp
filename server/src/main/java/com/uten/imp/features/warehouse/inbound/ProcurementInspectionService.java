package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.application.port.ProcurementIqcRejectionPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.finance.ProcurementOrderClosurePolicy;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
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
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 采购/委外收货 IQC 待检隔离（镜像销售退货质检冻结的 sidecar 模式）。
 *
 * <p>收货审核调用 {@link #receive} 把每条收货明细写入 {@code procurement_inspection_items}
 * （PENDING，<b>不写 stock_balances</b>）。因此三个可用量口径（warehouseAvailableBase /
 * globalAvailableBase / v_stock_available）自然不含待检品——零改动、零口径漂移，这是比
 * "给 stock_balances 加 inspection_status 列"更稳的选型（详见 ADR）。
 *
 * <p>{@code PASS} 只形成品质放行事实和仓库待入库任务；它不再写库存，也不再推进生产。
 * 仓库确认对应的放行切片后，才由 {@link ProcurementIqcStockInService} 写可用库存并推进正式
 * 生产供给。{@code FAIL} 只记质量事实。收货红冲前须所有明细已结案（RESOLVED），由
 * {@link #reverseResolvedStock} 只反向仓库已经确认入库的数量。
 */
@Service
@RequiredArgsConstructor
public class ProcurementInspectionService implements ProcurementInspectionPort {

    private static final String PENDING = "PENDING";
    private static final String PARTIAL = "PARTIAL";
    private static final String RESOLVED = "RESOLVED";
    private static final String REVERSED = "REVERSED";
    private static final String HANDLE_AUTHORITY = "procurement_inspection:handle";

    /** 与 ChainNoticeService.EVENT_IQC_RESOLVED 对齐：IQC 整单结案结果回执。 */
    private static final String EVENT_IQC_RESOLVED = "PROCUREMENT_IQC_RESOLVED";
    /** 每个 PASS 切片立即形成仓库待入库提醒；实时任务投影才是权威。 */
    private static final String EVENT_IQC_STOCK_IN_PENDING =
            "PROCUREMENT_IQC_STOCK_IN_PENDING";
    /** 与 ChainNoticeService.EVENT_IQC_PENDING 对齐：仓库审核收货 → 通知品质部进入待检。 */
    private static final String EVENT_IQC_PENDING = "PROCUREMENT_IQC_PENDING";
    /**
     * Quality-owned detection only.  The async outbox processor projects the
     * finance case; FAIL never queries AP or a finance table in this transaction.
     */
    private static final String EVENT_IQC_REJECTION_DETECTED =
            "PROCUREMENT_IQC_REJECTION_DETECTED";

    private final EntityManager em;
    private final StockService stockService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionSupplyTransitionPort purchaseSupply;
    private final ProductionSubcontractSupplyTransitionPort subcontractSupply;
    private final BusinessEventPublisher outbox;
    private final ProcurementIqcRejectionPort rejectionPort;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;

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
            BigDecimal receivedWeight = normalizeOptionalWeight(l.weight());
            UUID inspectionItemId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO procurement_inspection_items (
                        id, receipt_type, receipt_id, receipt_item_id, warehouse_id, goods_id,
                        color_id, unit_id, unit_rate, received_base_qty, received_amount_local,
                        received_weight, received_at
                    ) VALUES (
                        :id, :receiptType, :receiptId, :receiptItemId, :warehouseId, :goodsId,
                        :colorId, :unitId, :unitRate, :receivedBase, :amount,
                        :receivedWeight, :receivedAt
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
                    .setParameter("receivedWeight", receivedWeight)
                    .setParameter("receivedAt", receivedAt)
                    .executeUpdate();
            appendEvent(UUID.randomUUID(), inspectionItemId, "RECEIVED", receivedBase, null, actor, receivedAt);
        }
        if (!lines.isEmpty()) {
            // 收货单可能有多条明细，但品质任务按收货单聚合；同事务只投递一个幂等事件。
            outbox.publishOnce(
                    EVENT_IQC_PENDING,
                    "PROCUREMENT_INSPECTION",
                    receiptId,
                    Map.of("receiptType", receiptType),
                    EVENT_IQC_PENDING + ':' + receiptId);
        }
    }

    /**
     * 同一收货单的多行合格放行：先锁定库存维度和整张收货单全部 IQC 行，校验完整集合及
     * 操作人看到的剩余量，再复用单行结论链。外层事务保证任一库存/分析/供给副作用失败时
     * 整批回滚；每行独立幂等键保证响应丢失后的同体重放不会重复入库。
     */
    @Transactional
    @PreAuthorize("hasAuthority('procurement_inspection:view')"
            + " and hasAuthority('procurement_inspection:handle')")
    public void passBatch(
            String receiptType,
            UUID receiptId,
            BatchInspectionPassRequest request) {
        tx.bind();
        if (request == null || request.items() == null || request.items().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量合格明细不能为空");
        }
        if (request.items().size() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次最多合格放行 100 条明细");
        }
        String reason = normalizeDispositionReason("PASS", request.reason());
        HashSet<UUID> uniqueIds = new HashSet<>();
        List<NormalizedBatchPassItem> commands = new ArrayList<>();
        for (BatchInspectionPassRequest.Item item : request.items()) {
            if (item == null || item.inspectionItemId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量合格明细 ID 不能为空");
            }
            if (!uniqueIds.add(item.inspectionItemId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量合格明细不能重复");
            }
            commands.add(new NormalizedBatchPassItem(
                    item.inspectionItemId(),
                    normalizeQty(item.expectedRemainingBaseQty()),
                    normalizeIdempotencyKey(item.idempotencyKey())));
        }
        commands.sort(Comparator.comparing(command -> command.inspectionItemId().toString()));

        // 与单行处置相同：库存维度锁必须先于业务行锁。
        lockReceiptMutationDimensions(receiptType, receiptId);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, warehouse_id, goods_id, color_id, unit_id, unit_rate,
                               received_base_qty, received_amount_local,
                               passed_base_qty, failed_base_qty, status, receipt_type,
                               received_weight, received_weight_unit_id
                        FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getResultList();

        int replayCount = 0;
        for (NormalizedBatchPassItem command : commands) {
            UUID eventId = dispositionEventId(command.inspectionItemId(), command.idempotencyKey());
            if (replayRequiresWarehouseStockIn(
                    eventId,
                    command.inspectionItemId(),
                    "PASS",
                    command.expectedRemainingBaseQty(),
                    reason) != null) {
                replayCount++;
            }
        }
        if (replayCount != 0 && replayCount != commands.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "批量合格请求只部分匹配历史记录，请刷新后重试");
        }

        if (replayCount == 0) {
            for (NormalizedBatchPassItem command : commands) {
                Object[] row = rows.stream()
                        .filter(candidate -> command.inspectionItemId().equals(candidate[0]))
                        .findFirst()
                        .orElse(null);
                if (row == null) {
                    throw new ApiException(ErrorCode.NOT_FOUND, "批量合格明细不存在或不属于当前收货单");
                }
                String currentStatus = (String) row[10];
                if (!PENDING.equals(currentStatus) && !PARTIAL.equals(currentStatus)) {
                    throw new ApiException(ErrorCode.CONFLICT, "批量合格明细状态已变化，请刷新后重试");
                }
                BigDecimal remaining = dec(row[6]).subtract(dec(row[8])).subtract(dec(row[9]));
                if (remaining.compareTo(command.expectedRemainingBaseQty()) != 0) {
                    throw new ApiException(ErrorCode.CONFLICT, "批量合格明细待检数量已变化，请刷新后重试");
                }
            }
        }

        for (NormalizedBatchPassItem command : commands) {
            dispose(
                    receiptType,
                    receiptId,
                    command.inspectionItemId(),
                    new InspectionDispositionRequest(
                            "PASS",
                            command.expectedRemainingBaseQty(),
                            reason,
                            command.idempotencyKey()));
        }
    }

    private record NormalizedBatchPassItem(
            UUID inspectionItemId,
            BigDecimal expectedRemainingBaseQty,
            String idempotencyKey) {
    }

    /**
     * 受控质检结论：{@code PASS} 只放行到仓库待入库队列；{@code FAIL} 只记质量事实。
     * 两者都不改变可用库存。事件账幂等（同键同命令静默重放，同键异命令 409）。
     */
    @Transactional
    @PreAuthorize("hasAuthority('procurement_inspection:view')"
            + " and hasAuthority('procurement_inspection:handle')")
    public void dispose(String receiptType, UUID receiptId, UUID inspectionItemId,
                        InspectionDispositionRequest request) {
        tx.bind();
        if (request == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "质检结论请求不能为空");
        }
        String action = normalizeAction(request.action());
        String reason = normalizeDispositionReason(action, request.reason());
        // baseQty 可空（傻瓜式）：不传 = 全部剩余待检量。
        BigDecimal requested = request.baseQty() == null ? null : normalizeQty(request.baseQty());
        String idempotencyKey = normalizeIdempotencyKey(request.idempotencyKey());

        // Match receipt approval/reversal: acquire every inventory-dimension
        // advisory lock before any inspection row lock. Locking the complete
        // receipt below also serializes concurrent last-line dispositions, so
        // exactly one transaction observes whole-receipt completion.
        lockReceiptMutationDimensions(receiptType, receiptId);

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, warehouse_id, goods_id, color_id, unit_id, unit_rate,
                               received_base_qty, received_amount_local,
                               passed_base_qty, failed_base_qty, status, receipt_type,
                               received_weight, received_weight_unit_id
                        FROM procurement_inspection_items
                        WHERE receipt_type = :rt AND receipt_id = :rid
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getResultList();
        Object[] row = rows.stream()
                .filter(candidate -> inspectionItemId.equals(candidate[0]))
                .findFirst()
                .orElse(null);
        if (row == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "待检明细不存在");
        }
        if (!Objects.equals(receiptType, row[11])) {
            throw new ApiException(ErrorCode.CONFLICT, "质检结论的单据类型不一致");
        }
        UUID eventId = dispositionEventId(inspectionItemId, idempotencyKey);
        Boolean replayRequiresWarehouseStockIn = replayRequiresWarehouseStockIn(
                eventId, inspectionItemId, action, requested, reason);
        if (replayRequiresWarehouseStockIn != null) {
            // Older concurrent dispositions may have committed every line without
            // publishing the whole-receipt wake marker. A same-command replay owns
            // the receipt-scoped row locks above, so it can safely repair that state.
            boolean wholeReceiptResolved = allResolved(receiptType, receiptId);
            switch (replayNotification(action, replayRequiresWarehouseStockIn)) {
                case STOCK_IN_PENDING -> publishIqcStockInPending(
                        receiptType, receiptId, inspectionItemId, eventId);
                case REJECTION_DETECTED -> publishIqcRejectionDetected(
                        receiptType, receiptId, inspectionItemId, eventId);
                case NONE -> {
                    // Historical PASS was already posted before V446. Replaying it
                    // must not fabricate either a warehouse task or a FAIL event.
                }
            }
            recalculateOrderClosure(receiptType, receiptId);
            wakeIfWholeReceiptResolved(
                    receiptType,
                    receiptId,
                    OffsetDateTime.now(),
                    wholeReceiptResolved);
            return;
        }

        String currentStatus = (String) row[10];
        if (!PENDING.equals(currentStatus) && !PARTIAL.equals(currentStatus)) {
            throw new ApiException(ErrorCode.CONFLICT, "该待检明细已全部结案或已撤销");
        }
        BigDecimal received = dec(row[6]);
        BigDecimal passed = dec(row[8]);
        BigDecimal failed = dec(row[9]);
        BigDecimal resolvedBefore = passed.add(failed);
        BigDecimal remaining = received.subtract(passed).subtract(failed);
        if (requested == null) {
            requested = remaining; // 不传量 = 全量处置（傻瓜式一键合格/不合格）
        }
        if (requested.signum() <= 0 || requested.compareTo(remaining) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "质检数量必须大于 0 且不得超过待检数量 " + remaining.stripTrailingZeros().toPlainString());
        }

        OffsetDateTime now = OffsetDateTime.now();
        UUID actor = currentUser.requireEmployeeId();
        BigDecimal releasedAmount = "PASS".equals(action)
                ? proratedIncrement(dec(row[7]), received, resolvedBefore, requested)
                : null;
        UUID receivedWeightUnitId = (UUID) row[13];
        BigDecimal trustedReceivedWeight = nullableDec(row[12]);
        BigDecimal releasedWeight = "PASS".equals(action)
                ? proratedIncrementNullable(
                        trustedReceivedWeight, received, resolvedBefore, requested)
                : null;
        UUID releasedWeightUnitId = releasedWeight == null
                ? null : receivedWeightUnitId;
        if ("PASS".equals(action)) {
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
        appendEvent(
                eventId, inspectionItemId, action, requested, reason, actor, now,
                releasedAmount, releasedWeight, releasedWeightUnitId);
        if ("PASS".equals(action)) {
            publishIqcStockInPending(
                    receiptType, receiptId, inspectionItemId, eventId);
        } else {
            publishIqcRejectionDetected(
                    receiptType, receiptId, inspectionItemId, eventId);
        }

        boolean wholeReceiptResolved = allResolved(receiptType, receiptId);
        recalculateOrderClosure(receiptType, receiptId);

        // 整单结案事件/通知仍按收货单只发一次；每个 PASS 切片只生成仓库待入库任务，
        // 正式生产供给仅按仓库已确认入库量推进。
        wakeIfWholeReceiptResolved(
                receiptType, receiptId, now, wholeReceiptResolved);
        // V459 办结撤回：整单检验结案后撤回全部品质人员的待检弹卡（幂等）。
        if (wholeReceiptResolved) {
            chainNotice.resolveReviewNotices(
                    "IQC_INSPECTION", receiptId, "INSPECTED");
        }
    }

    private void publishIqcStockInPending(
            String receiptType,
            UUID receiptId,
            UUID inspectionItemId,
            UUID passEventId) {
        outbox.publishOnce(
                EVENT_IQC_STOCK_IN_PENDING,
                "PROCUREMENT_INSPECTION_PASS",
                passEventId,
                Map.of(
                        "receiptType", receiptType,
                        "receiptId", receiptId,
                        "inspectionItemId", inspectionItemId),
                EVENT_IQC_STOCK_IN_PENDING + ':' + passEventId);
    }

    private void publishIqcRejectionDetected(
            String receiptType,
            UUID receiptId,
            UUID inspectionItemId,
            UUID inspectionEventId) {
        outbox.publishOnce(
                EVENT_IQC_REJECTION_DETECTED,
                "PROCUREMENT_INSPECTION_ITEM",
                inspectionItemId,
                Map.of(
                        "receiptType", receiptType,
                        "receiptId", receiptId,
                        "inspectionEventId", inspectionEventId),
                EVENT_IQC_REJECTION_DETECTED + ':' + inspectionEventId);
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
        rejectionPort.beforeReceiptReverse(receiptType, receiptId);
    }

    /**
     * 收货红冲同事务调用：只反向仓库已确认入库量，并置冻结行 REVERSED。
     * 返回是否管理了该单（有冻结行）；无冻结行时调用方走历史全量反向。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean reverseResolvedStock(String receiptType, UUID receiptId, OffsetDateTime now) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, warehouse_id, goods_id, color_id, unit_id, unit_rate,
                               warehouse_stocked_base_qty,
                               warehouse_stocked_amount_local,
                               warehouse_stocked_weight,
                               status, received_weight_unit_id
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
            BigDecimal stocked = dec(row[6]);
            if (stocked.signum() > 0) {
                stockService.recordMovement(new StockService.MovementRequest(
                        now, movementType(receiptType), sourceDocType(receiptType),
                        receiptId, inspectionItemId, (UUID) row[2], (UUID) row[3], (UUID) row[1],
                        StockService.DIR_OUT, stocked, (UUID) row[4], dec(row[5]), dec(row[7]),
                        "红冲收货，反向仓库已确认 IQC 入库", nullableDec(row[8]),
                        (UUID) row[10]));
            }
            int updated = em.createNativeQuery("""
                    UPDATE procurement_inspection_items
                    SET passed_base_qty = 0,
                        failed_base_qty = 0,
                        warehouse_stocked_base_qty = 0,
                        warehouse_stocked_amount_local = 0,
                        warehouse_stocked_weight = CASE
                            WHEN received_weight IS NULL THEN NULL ELSE 0 END,
                        status = 'REVERSED',
                        updated_at = :now
                    WHERE id = :id AND status = 'RESOLVED'
                    """)
                    .setParameter("now", now)
                    .setParameter("id", inspectionItemId)
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "IQC 明细状态已变化，请刷新后重试");
            }
            appendEvent(UUID.randomUUID(), inspectionItemId, "RECEIPT_REVERSED", stocked, null, actor, now);
        }
        return true;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    @SuppressWarnings("unchecked")
    public List<Object[]> pendingForReceipt(String receiptType, UUID receiptId) {
        return em.createNativeQuery("""
                        SELECT i.id, i.receipt_item_id, i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                               i.received_base_qty, i.passed_base_qty, i.failed_base_qty, i.status,
                               g.code, g.name, col.name, i.warehouse_id,
                               COALESCE(po.bill_no, so.bill_no), i.received_weight
                        FROM procurement_inspection_items i
                        LEFT JOIN goods g ON g.id = i.goods_id
                        LEFT JOIN colors col ON col.id = i.color_id
                        LEFT JOIN purchase_receipt_items pri
                               ON i.receipt_type = 'PURCHASE' AND pri.id = i.receipt_item_id
                        LEFT JOIN purchase_order_items poi ON poi.id = pri.order_item_id
                        LEFT JOIN purchase_orders po ON po.id = poi.order_id
                        LEFT JOIN subcontract_receipt_items sri
                               ON i.receipt_type = 'SUBCONTRACT' AND sri.id = i.receipt_item_id
                        LEFT JOIN subcontract_order_items soi ON soi.id = sri.order_item_id
                        LEFT JOIN subcontract_orders so ON so.id = soi.order_id
                        WHERE i.receipt_type = :rt AND i.receipt_id = :rid
                        ORDER BY i.received_at, i.id
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getResultList();
    }

    /**
     * 全局待检单列表（IQC 工作台入口）：按收货单聚合仍有 PENDING/PARTIAL 明细的采购/委外
     * 收货单，含单号/日期/供应商/仓库与待检件数、待检量（基本单位），供质检员逐单下钻处置。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    @SuppressWarnings("unchecked")
    public List<Object[]> pendingReceiptSummaries() {
        return em.createNativeQuery("""
                        WITH agg AS (
                            SELECT receipt_type, receipt_id,
                                   COUNT(*) AS item_count,
                                   SUM(received_base_qty - passed_base_qty - failed_base_qty) AS pending_base_qty,
                                   MIN(received_at) AS first_received_at,
                                   MAX(received_at) AS last_received_at,
                                   -- PG 无 min(uuid) 聚合：同一收货单明细同仓，取文本序最小仓转回 uuid。
                                   MIN(warehouse_id::text)::uuid AS warehouse_id
                            FROM procurement_inspection_items
                            WHERE status IN ('PENDING', 'PARTIAL')
                            GROUP BY receipt_type, receipt_id
                        )
                        SELECT a.receipt_type, a.receipt_id, a.item_count, a.pending_base_qty,
                               a.first_received_at, a.last_received_at, a.warehouse_id,
                               x.bill_no, x.bill_date, x.supplier_id, s.name
                        FROM agg a
                        JOIN (
                            SELECT 'PURCHASE'::text AS t, id, bill_no, bill_date, supplier_id
                            FROM purchase_receipts WHERE COALESCE(is_deleted, false) = false
                            UNION ALL
                            SELECT 'SUBCONTRACT'::text, id, bill_no, bill_date, supplier_id
                            FROM subcontract_receipts WHERE COALESCE(is_deleted, false) = false
                        ) x ON x.t = a.receipt_type AND x.id = a.receipt_id
                        LEFT JOIN suppliers s ON s.id = x.supplier_id
                        ORDER BY a.first_received_at
                        LIMIT 200
                        """)
                .getResultList();
    }

    // ---- helpers ----

    /** 待检处置角标计数：仍有 PENDING/PARTIAL 明细的收货单张数。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public long pendingReceiptCount() {
        return ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM (
                            SELECT receipt_type, receipt_id
                            FROM procurement_inspection_items
                            WHERE status IN ('PENDING', 'PARTIAL')
                            GROUP BY receipt_type, receipt_id
                        ) pending
                        """)
                .getSingleResult()).longValue();
    }

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

    private boolean alreadyReceiptResolved(String receiptType, UUID receiptId) {
        Integer resolved = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM procurement_inspection_events e
                        JOIN procurement_inspection_items i ON i.id = e.inspection_item_id
                        WHERE e.action IN ('PRODUCTION_WOKEN', 'RECEIPT_RESOLVED')
                          AND i.receipt_type = :rt AND i.receipt_id = :rid
                        """)
                .setParameter("rt", receiptType)
                .setParameter("rid", receiptId)
                .getSingleResult()).intValue();
        return resolved > 0;
    }

    private void wakeIfWholeReceiptResolved(
            String receiptType,
            UUID receiptId,
            OffsetDateTime now,
            boolean wholeReceiptResolved) {
        if (!wholeReceiptResolved || alreadyReceiptResolved(receiptType, receiptId)) {
            return;
        }
        // Reconcile quality-terminal shortage/replacement projections once.
        // The transition services now read warehouse_stocked_base_qty, so this
        // callback cannot turn an unstocked PASS quantity into READY inventory.
        reconcileProductionAfterQualityResolved(receiptType, receiptId);
        appendReceiptEvent(
                receiptType,
                receiptId,
                "RECEIPT_RESOLVED",
                BigDecimal.ZERO,
                "整单质检结案；合格量须由仓库确认后才进入可用库存",
                currentUser.requireEmployeeId(),
                now);
        // 整单品质结果回执；仓库待办已由每个 PASS 切片即时投递。
        outbox.publishOnce(
                EVENT_IQC_RESOLVED,
                "PROCUREMENT_INSPECTION",
                receiptId,
                Map.of("receiptType", receiptType),
                EVENT_IQC_RESOLVED + ':' + receiptId);
    }

    private void reconcileProductionAfterQualityResolved(
            String receiptType, UUID receiptId) {
        if (PURCHASE.equals(receiptType)) {
            purchaseSupply.onPurchaseReceiptApproved(receiptId);
        } else {
            subcontractSupply.onSubcontractReceiptApproved(receiptId);
        }
    }

    private void recalculateOrderClosure(String receiptType, UUID receiptId) {
        String receiptItemTable = PURCHASE.equals(receiptType)
                ? "purchase_receipt_items"
                : "subcontract_receipt_items";
        @SuppressWarnings("unchecked")
        List<UUID> orderItemIds = em.createNativeQuery("""
                        SELECT DISTINCT order_item_id
                        FROM %s
                        WHERE receipt_id=:receiptId
                          AND order_item_id IS NOT NULL
                          AND COALESCE(is_deleted,FALSE)=FALSE
                        ORDER BY order_item_id
                        """.formatted(receiptItemTable))
                .setParameter("receiptId", receiptId)
                .getResultList();
        for (UUID orderItemId : orderItemIds) {
            ProcurementOrderClosurePolicy.recalculate(
                    em, receiptType, orderItemId);
        }
    }

    private void lockReceiptMutationDimensions(String receiptType, UUID receiptId) {
        if (PURCHASE.equals(receiptType)) {
            purchaseSupply.lockPurchaseReceiptMutationDimensions(receiptId);
        } else if (SUBCONTRACT.equals(receiptType)) {
            subcontractSupply.lockSubcontractReceiptMutationDimensions(receiptId);
        } else {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "收货单类型无效");
        }
    }

    private Boolean replayRequiresWarehouseStockIn(
            UUID eventId,
            UUID inspectionItemId,
            String action,
            BigDecimal requested,
            String reason) {
        @SuppressWarnings("unchecked")
        List<Object[]> events = em.createNativeQuery("""
                        SELECT inspection_item_id, action, base_qty, reason,
                               requires_warehouse_stock_in
                        FROM procurement_inspection_events WHERE id = :id
                        """)
                .setParameter("id", eventId)
                .getResultList();
        if (events.isEmpty()) return null;
        Object[] ex = events.getFirst();
        if (Objects.equals(ex[0], inspectionItemId)
                && Objects.equals(ex[1], action)
                // requested == null means a full-quantity ("一键合格") disposition; the stored
                // event was itself full at its moment, so a retried full disposition is a replay
                // regardless of the (since-changed) stored base_qty. Skip the qty compare to avoid
                // NPE'ing on the null and to keep the retry idempotent.
                && (requested == null || dec(ex[2]).compareTo(requested) == 0)
                && Objects.equals(ex[3], reason)) {
            return (Boolean) ex[4];
        }
        throw new ApiException(ErrorCode.CONFLICT, "该质检幂等键已用于不同结论，请刷新后重新操作");
    }

    static ReplayNotification replayNotification(
            String action, Boolean requiresWarehouseStockIn) {
        if ("PASS".equals(action)) {
            return Boolean.TRUE.equals(requiresWarehouseStockIn)
                    ? ReplayNotification.STOCK_IN_PENDING
                    : ReplayNotification.NONE;
        }
        return ReplayNotification.REJECTION_DETECTED;
    }

    enum ReplayNotification {
        STOCK_IN_PENDING,
        REJECTION_DETECTED,
        NONE
    }

    private void appendEvent(UUID eventId, UUID inspectionItemId, String action,
                             BigDecimal baseQty, String reason, UUID actor, OffsetDateTime occurredAt) {
        appendEvent(
                eventId, inspectionItemId, action, baseQty, reason, actor, occurredAt,
                null, null, null);
    }

    private void appendEvent(
            UUID eventId,
            UUID inspectionItemId,
            String action,
            BigDecimal baseQty,
            String reason,
            UUID actor,
            OffsetDateTime occurredAt,
            BigDecimal releasedAmountLocal,
            BigDecimal releasedWeight,
            UUID releasedWeightUnitId) {
        em.createNativeQuery("""
                INSERT INTO procurement_inspection_events (
                    id, inspection_item_id, action, base_qty, reason,
                    actor_employee_id, occurred_at, requires_warehouse_stock_in,
                    released_amount_local, released_weight, released_weight_unit_id
                ) VALUES (
                    :id, :iid, :action, :qty, :reason,
                    :actor, :at, :requiresWarehouseStockIn,
                    :releasedAmountLocal, :releasedWeight, :releasedWeightUnitId)
                """)
                .setParameter("id", eventId)
                .setParameter("iid", inspectionItemId)
                .setParameter("action", action)
                .setParameter("qty", baseQty)
                .setParameter("reason", reason)
                .setParameter("actor", actor)
                .setParameter("at", occurredAt)
                .setParameter("requiresWarehouseStockIn", "PASS".equals(action))
                .setParameter("releasedAmountLocal", releasedAmountLocal)
                .setParameter("releasedWeight", releasedWeight)
                .setParameter("releasedWeightUnitId", releasedWeightUnitId)
                .executeUpdate();
    }

    /** 收货单级结案标记挂在任一明细事件上（取第一条），按 receipt 查重。 */
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

    static BigDecimal proratedIncrementNullable(
            BigDecimal sourceWeight, BigDecimal receivedBase,
            BigDecimal alreadyPassed, BigDecimal passBase) {
        return sourceWeight == null ? null : proratedIncrement(
                sourceWeight, receivedBase, alreadyPassed, passBase);
    }

    private BigDecimal actionAllocatedAmount(
            UUID inspectionItemId,BigDecimal sourceTotal,
            BigDecimal receivedBase,String wantedAction,BigDecimal fallbackBase){
        @SuppressWarnings("unchecked")
        List<Object[]> events=em.createNativeQuery("""
                SELECT action,base_qty
                FROM procurement_inspection_events
                WHERE inspection_item_id=:inspectionItemId
                  AND action IN('PASS','FAIL')
                ORDER BY occurred_at,id
                """).setParameter("inspectionItemId",inspectionItemId).getResultList();
        if(events.isEmpty()){
            return proratedIncrement(
                    sourceTotal,receivedBase,BigDecimal.ZERO,fallbackBase);
        }
        BigDecimal resolvedBefore=BigDecimal.ZERO;
        BigDecimal selected=BigDecimal.ZERO;
        for(Object[] event:events){
            BigDecimal sliceBase=dec(event[1]);
            BigDecimal slice=proratedIncrement(
                    sourceTotal,receivedBase,resolvedBefore,sliceBase);
            if(wantedAction.equals(event[0]))selected=selected.add(slice);
            resolvedBefore=resolvedBefore.add(sliceBase);
        }
        if(resolvedBefore.compareTo(receivedBase)!=0){
            throw new ApiException(
                    ErrorCode.CONFLICT,"IQC处置事件数量与冻结行不守恒，禁止红冲");
        }
        return selected;
    }

    private BigDecimal actionAllocatedAmountNullable(
            UUID inspectionItemId,BigDecimal sourceTotal,
            BigDecimal receivedBase,String wantedAction,BigDecimal fallbackBase){
        return sourceTotal==null?null:actionAllocatedAmount(
                inspectionItemId,sourceTotal,receivedBase,wantedAction,fallbackBase);
    }

    static String normalizeAction(String action) {
        String n = action == null ? "" : action.trim().toUpperCase(Locale.ROOT);
        if (!"PASS".equals(n) && !"FAIL".equals(n)) {
            throw new ApiException(ErrorCode.BUSINESS, "质检结论仅支持 PASS 或 FAIL");
        }
        return n;
    }

    static String normalizeDispositionReason(String action, String rawReason) {
        String reason = rawReason == null ? null : rawReason.trim();
        if (reason != null && reason.isEmpty()) reason = null;
        if ("FAIL".equals(action) && reason == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不合格原因不能为空");
        }
        if (reason != null && reason.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "质检结论原因不能超过 500 个字符");
        }
        return reason;
    }

    static String passMovementRemark(String reason) {
        return reason == null ? "IQC 合格放行" : "IQC 合格放行：" + reason;
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

    private static BigDecimal normalizeOptionalWeight(BigDecimal weight) {
        if (weight == null) return null;
        if (weight.signum() < 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "收货明细实际总重量不得为负数");
        }
        try {
            BigDecimal normalized = weight.setScale(4, RoundingMode.UNNECESSARY);
            if (normalized.precision() - normalized.scale() > 14) {
                throw new ApiException(
                        ErrorCode.CONFLICT, "收货明细实际总重量整数位最多 14 位");
            }
            return normalized;
        } catch (ArithmeticException ex) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "收货明细实际总重量最多保留 4 位小数");
        }
    }

    private static BigDecimal dec(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static BigDecimal nullableDec(Object value) {
        return value == null ? null : (BigDecimal) value;
    }
}
