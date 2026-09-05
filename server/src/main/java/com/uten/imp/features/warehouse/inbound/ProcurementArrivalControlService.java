package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.ProcurementArrivalBlockedException;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.PreplanInboundAllocationReadPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalDecisionRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.GoodsProfileHintRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.InboundAllocation;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ReturnCompletionRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.SupplierReturnTask;
import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Fail-closed arrival authority for financially approved purchase and
 * subcontract orders.
 *
 * <p>Notifications are reminders only. Every actionable task and decision is
 * persisted here. Finance decisions are restricted to the exact configured
 * finance assignee snapshot; supplier-return completion is restricted to the
 * exact original order-maker account.
 */
@Service
public class ProcurementArrivalControlService implements ProcurementArrivalControlPort {

    public static final String EVENT_DETECTED = "PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED";
    public static final String EVENT_DECIDED = "PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED";
    public static final String EVENT_RETURN_REQUIRED = "PROCUREMENT_SUPPLIER_RETURN_REQUIRED";
    public static final String EVENT_RETURN_COMPLETED = "PROCUREMENT_SUPPLIER_RETURN_COMPLETED";
    public static final String EVENT_RECEIPT_POSTED = "PROCUREMENT_ARRIVAL_RECEIPT_POSTED";

    private static final String PENDING_FINANCE = "PENDING_FINANCE";
    private static final String RECEIPT_ADJUSTED = "RECEIPT_ADJUSTED";
    private static final String RETURN_REQUIRED = "RETURN_REQUIRED";
    private static final String RECEIPT_POSTED = "RECEIPT_POSTED";
    private static final String CLOSED = "CLOSED";

    /** 预计到货搜索关键字参数个数：单号 / 供应商 / 货品编码 / 货品名称。 */
    private static final int EXPECTATION_KEYWORD_PARAMS = 4;

    /**
     * 预计到货任务中心可见口径（2026-09-01 起）：送检即移交品质——「已送检 · 待品质
     * 检验」不再占用本页视野，改在「品质部检查结果」页以 等待检查结果/全部合格/
     * 部分合格/全部不合格 跟踪。本页只保留仓库仍有活干的任务：还有可登记容量、
     * 或挂着草稿收货单（待继续送检）、或有未结到货异常（待财务定案）。
     * CLOSED 任务不再因等待品质而回流（原 PENDING_INSPECTION_EXISTS 口径已下线）。
     */
    private static String warehouseWorkRemaining() {
        return """
                (expectation.status = 'OPEN' AND (
                    EXISTS (
                        SELECT 1 FROM inbound_expectation_items cap_item
                        WHERE cap_item.expectation_id = expectation.id
                          AND (%s) > 0
                    )
                    OR EXISTS (
                        SELECT 1 FROM inbound_expectation_items draft_item
                        JOIN purchase_receipt_items draft_purchase_ri
                          ON draft_purchase_ri.order_item_id = draft_item.order_item_id
                        JOIN purchase_receipts draft_purchase_r
                          ON draft_purchase_r.id = draft_purchase_ri.receipt_id
                         AND draft_purchase_r.status = 0
                         AND draft_purchase_r.is_deleted = FALSE
                        WHERE draft_item.expectation_id = expectation.id
                    ) OR EXISTS (
                        SELECT 1 FROM inbound_expectation_items draft_item
                        JOIN subcontract_receipt_items draft_sub_ri
                          ON draft_sub_ri.order_item_id = draft_item.order_item_id
                        JOIN subcontract_receipts draft_sub_r
                          ON draft_sub_r.id = draft_sub_ri.receipt_id
                         AND draft_sub_r.status = 0
                         AND draft_sub_r.is_deleted = FALSE
                        WHERE draft_item.expectation_id = expectation.id
                    ) OR EXISTS (
                        SELECT 1 FROM inbound_expectation_items exc_item
                        JOIN procurement_arrival_exceptions exc
                          ON exc.order_item_id = exc_item.order_item_id
                        WHERE exc_item.expectation_id = expectation.id
                          AND exc.status NOT IN ('CLOSED','CANCELED')
                    )
                ))
                """.formatted(currentReceivableQty("cap_item"));
    }

    /**
     * 当前预计到货行还能登记的数量。采购和历史委外沿用财务快照；V436 新委外
     * 只释放已经审核出仓的目标件数量，并扣除已审核回厂。IQC 失败已实物退回的
     * 总量按 V440 加回；补货收货仍由“全部已审核回厂”统一扣除，不能再按 ACTIVE
     * allocation 重复扣减。最终容量仍受订单净未收量约束。
     */
    private static String currentReceivableQty(String itemAlias) {
        return """
                CASE
                  WHEN NOT EXISTS (
                      SELECT 1
                      FROM subcontract_material_plan_items release_plan
                      WHERE release_plan.order_item_id = %1$s.order_item_id
                        AND release_plan.flow_mode IN (
                            'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                        AND release_plan.is_deleted = FALSE
                  ) THEN GREATEST(%1$s.ordered_qty - %1$s.accepted_qty, 0)
                  ELSE LEAST(
                      GREATEST(%1$s.ordered_qty - %1$s.accepted_qty, 0),
                      GREATEST((
                          COALESCE((
                              SELECT SUM(issue_item.qty
                                  * COALESCE(issue_item.unit_rate, 1))
                              FROM subcontract_material_issue_items issue_item
                              JOIN subcontract_material_issues issue
                                ON issue.id = issue_item.issue_id
                               AND issue.status = 1
                               AND issue.is_deleted = FALSE
                              JOIN subcontract_material_plan_items issue_plan
                                ON issue_plan.id = issue_item.plan_item_id
                               AND issue_plan.flow_mode IN (
                                   'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                               AND issue_plan.is_deleted = FALSE
                              WHERE issue_item.order_item_id = %1$s.order_item_id
                                AND issue_item.is_deleted = FALSE
                          ), 0)
                          + COALESCE((
                              SELECT SUM(rejection.failed_base_qty)
                              FROM procurement_iqc_rejection_cases rejection
                              WHERE rejection.receipt_type = 'SUBCONTRACT'
                                AND rejection.order_item_id = %1$s.order_item_id
                                AND rejection.is_deleted = FALSE
                                AND rejection.return_recorded_at IS NOT NULL
                                AND rejection.status IN (
                                    'RETURN_RECORDED','CREDIT_CONFIRMED',
                                    'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                          ), 0)
                          - COALESCE((
                              SELECT SUM(receipt_item.qty
                                  * COALESCE(receipt_item.unit_rate, 1))
                              FROM subcontract_receipt_items receipt_item
                              JOIN subcontract_receipts receipt
                                ON receipt.id = receipt_item.receipt_id
                               AND receipt.status = 1
                               AND receipt.is_deleted = FALSE
                              WHERE receipt_item.order_item_id = %1$s.order_item_id
                                AND receipt_item.is_deleted = FALSE
                          ), 0)
                      ) / NULLIF(%1$s.unit_rate, 0), 0)
                  )
                END
                """.formatted(itemAlias);
    }

    /** 一条委外预计到货明细正在等待登记、续办、品质或异常处理。 */
    private static String subcontractItemVisible(String itemAlias) {
        return """
                ((%2$s) > 0
                 OR EXISTS (
                     SELECT 1
                     FROM subcontract_receipt_items visible_draft_item
                     JOIN subcontract_receipts visible_draft
                       ON visible_draft.id = visible_draft_item.receipt_id
                      AND visible_draft.status = 0
                      AND visible_draft.is_deleted = FALSE
                     WHERE visible_draft_item.order_item_id = %1$s.order_item_id
                       AND visible_draft_item.is_deleted = FALSE)
                 OR EXISTS (
                     SELECT 1
                     FROM subcontract_receipt_items visible_quality_item
                     JOIN subcontract_receipts visible_quality_receipt
                       ON visible_quality_receipt.id = visible_quality_item.receipt_id
                      AND visible_quality_receipt.status = 1
                      AND visible_quality_receipt.is_deleted = FALSE
                     JOIN procurement_inspection_items visible_inspection
                       ON visible_inspection.receipt_item_id = visible_quality_item.id
                      AND visible_inspection.receipt_type = 'SUBCONTRACT'
                      AND visible_inspection.status IN ('PENDING','PARTIAL')
                     WHERE visible_quality_item.order_item_id = %1$s.order_item_id
                       AND visible_quality_item.is_deleted = FALSE)
                 OR EXISTS (
                     SELECT 1
                     FROM procurement_arrival_exceptions visible_exception
                     WHERE visible_exception.order_type = 'SUBCONTRACT'
                       AND visible_exception.order_item_id = %1$s.order_item_id
                       AND visible_exception.status NOT IN ('CLOSED','CANCELED')))
                """.formatted(itemAlias, currentReceivableQty(itemAlias));
    }

    /** PURCHASE 财务批准即显示；SUBCONTRACT 只在真实出仓后的活动阶段显示。 */
    private static String expectationVisible() {
        return """
                (expectation.order_type <> 'SUBCONTRACT'
                 OR EXISTS (
                     SELECT 1
                     FROM inbound_expectation_items visible_item
                     WHERE visible_item.expectation_id = expectation.id
                       AND (%s)))
                """.formatted(subcontractItemVisible("visible_item"));
    }

    /** 搜索委外货品时也只匹配已释放/在途的行，不能由同单未出仓行把任务误搜出来。 */
    private static String expectationKeywordClause() {
        return """
                (expectation.bill_no_snapshot ILIKE ?
                 OR EXISTS (SELECT 1 FROM suppliers kw_supplier
                            WHERE kw_supplier.id = expectation.supplier_id
                              AND kw_supplier.name ILIKE ?)
                 OR EXISTS (SELECT 1 FROM inbound_expectation_items kw_item
                            JOIN goods kw_goods ON kw_goods.id = kw_item.goods_id
                            WHERE kw_item.expectation_id = expectation.id
                              AND (expectation.order_type <> 'SUBCONTRACT'
                                   OR (%s))
                              AND (kw_goods.code ILIKE ? OR kw_goods.name ILIKE ?)))
                """.formatted(subcontractItemVisible("kw_item"));
    }

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final BusinessEventPublisher events;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final FinanceReviewerEligibilityPort reviewerEligibility;
    private final ReceiptPriceMasker priceMasker;
    private PreplanInboundAllocationReadPort inboundAllocationRead =
            PreplanInboundAllocationReadPort.NOOP;

    public ProcurementArrivalControlService(
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            BusinessEventPublisher events,
            SecurityContextCurrentUser currentUser,
            TxSessionVars tx,
            FinanceReviewerEligibilityPort reviewerEligibility,
            ReceiptPriceMasker priceMasker) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
        this.events = events;
        this.currentUser = currentUser;
        this.tx = tx;
        this.reviewerEligibility = reviewerEligibility;
        this.priceMasker = priceMasker;
    }

    @Autowired
    void setInboundAllocationRead(PreplanInboundAllocationReadPort value) {
        this.inboundAllocationRead = value;
    }

    /**
     * Fail-closed gate run before a receipt is approved: every receipt line must trace to a
     * finance-approved order line; declared qty exceeding the remaining approved capacity is
     * recorded as a PENDING_FINANCE exception and the approve is blocked (the
     * ProcurementArrivalBlockedException is committed, not rolled back). Also refuses the
     * receipt when the same order line already has an open exception on a sibling receipt,
     * which would otherwise deadlock behind that receipt's overage guard.
     */
    @Override
    @Transactional(noRollbackFor = ProcurementArrivalBlockedException.class)
    public void validateBeforeApproval(String rawOrderType, UUID receiptId) {
        tx.bind();
        String orderType = requireOrderType(rawOrderType);
        List<ArrivalRow> rows = loadArrivalRows(orderType, receiptId);
        int persistedItems = countReceiptItems(orderType, receiptId);
        if (rows.size() != persistedItems) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "收货明细必须逐行关联财务已批准的订货明细，禁止无来源入库");
        }

        Map<UUID, ExistingException> existing = existingExceptions(orderType, receiptId);
        // 防重复收货单：同一订货明细若已在另一张收货单上产生未结到货异常，禁止再在别处审核入库。
        // 否则会出现「明细已被这张收货单收到满，而那张收货单的异常仍卡在 RECEIPT_ADJUSTED」的
        // 死锁态——那张异常的一键入库会被 received_qty 超量 guard 永久拦截，且 completeReturn
        // 不会把 RECEIPT_ADJUSTED 推进到 CLOSED，异常一直挂在任务中心。
        Map<UUID, String> siblingOpenException =
                siblingOpenExceptionReceipts(orderType, receiptId);
        Map<UUID, BigDecimal> baseRemaining = new HashMap<>();
        Map<UUID, BigDecimal> allocatedInReceipt = new HashMap<>();
        boolean blocked = false;
        boolean receiptBoundAllowance = false;
        for (ArrivalRow row : rows) {
            String blockingSibling = siblingOpenException.get(row.orderItemId());
            if (blockingSibling != null) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "该订货明细已在另一张收货单(" + blockingSibling
                                + ")上产生到货异常，请先在那张收货单完成一键入库或作废异常，再审核本单");
            }
            BigDecimal remaining = baseRemaining.computeIfAbsent(
                    row.orderItemId(), ignored -> approvedRemaining(row,orderType));
            BigDecimal beforeThisLine = allocatedInReceipt.getOrDefault(
                    row.orderItemId(), BigDecimal.ZERO);
            BigDecimal available = nonNegative(remaining.subtract(beforeThisLine));
            ExistingException exception = existing.get(row.receiptItemId());

            boolean exactlyFinanceAdjusted = exception != null
                    && RECEIPT_ADJUSTED.equals(exception.status())
                    && exception.acceptedQty() != null
                    && sameQuantity(exception.acceptedQty(), row.declaredQty());

            if (exception != null && PENDING_FINANCE.equals(exception.status())) {
                blocked = true;
            } else if (exactlyFinanceAdjusted) {
                receiptBoundAllowance = true;
            } else if (row.declaredQty().compareTo(available) > 0) {
                registerException(row, available, exception);
                blocked = true;
            } else if (exception != null
                    && !List.of(CLOSED, RECEIPT_POSTED, "CANCELED")
                            .contains(exception.status())) {
                registerException(row, available, exception);
                blocked = true;
            }

            BigDecimal capacityClaim = row.declaredQty().min(available);
            allocatedInReceipt.merge(row.orderItemId(), capacityClaim, BigDecimal::add);
        }
        if (receiptBoundAllowance) {
            bindReceiptAllowance(orderType, receiptId);
        }
        if (blocked) {
            throw new ProcurementArrivalBlockedException(
                    "实际到货超过财务已批准的可收数量；本次未入库、未立应付，已转交财务审核组共享待审");
        }
    }

    /**
     * Apply the finance-approved excess on receipt approval: bumps the order line's
     * arrival_overage_posted_qty and the expectation ordered_qty, then advances each
     * RECEIPT_ADJUSTED exception to RECEIPT_POSTED (a supplier return is still owed) or
     * CLOSED (fully accepted). The RECEIPT_POSTED notice is published only when a return
     * task is still pending, so fully-accepted receipts don't raise a follow-up alert.
     */
    @Override
    @Transactional
    public void recordApproval(String rawOrderType, UUID receiptId) {
        tx.bind();
        String orderType = requireOrderType(rawOrderType);
        List<PostedAllowance> allowances = jdbc.query("""
                SELECT id, order_item_id, expectation_item_id,
                       COALESCE(approved_excess_qty, 0) AS approved_excess_qty,
                       version
                FROM procurement_arrival_exceptions
                WHERE order_type = ? AND receipt_id = ?
                  AND status = 'RECEIPT_ADJUSTED'
                ORDER BY id
                FOR UPDATE
                """, (rs, rowNum) -> new PostedAllowance(
                        rs.getObject("id", UUID.class),
                        rs.getObject("order_item_id", UUID.class),
                        rs.getObject("expectation_item_id", UUID.class),
                        rs.getBigDecimal("approved_excess_qty"),
                        rs.getLong("version")),
                orderType, receiptId);
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        String orderItemTable = PURCHASE.equals(orderType)
                ? "purchase_order_items" : "subcontract_order_items";
        for (PostedAllowance allowance : allowances) {
            if (allowance.approvedExcessQty().signum() > 0) {
                requireChanged(jdbc.update("""
                        UPDATE %s
                        SET arrival_overage_posted_qty =
                                arrival_overage_posted_qty + ?
                        WHERE id = ?
                        """.formatted(orderItemTable),
                        allowance.approvedExcessQty(), allowance.orderItemId()));
                if (allowance.expectationItemId() != null) {
                    requireChanged(jdbc.update("""
                            UPDATE inbound_expectation_items
                            SET ordered_qty = ordered_qty + ?, updated_at = now()
                            WHERE id = ?
                            """, allowance.approvedExcessQty(),
                            allowance.expectationItemId()));
                }
            }
            requireChanged(jdbc.update("""
                    UPDATE procurement_arrival_exceptions exception_row
                    SET status = CASE WHEN EXISTS (
                            SELECT 1 FROM supplier_return_tasks return_task
                            WHERE return_task.arrival_exception_id = exception_row.id
                              AND return_task.status = 'PENDING_RETURN'
                        ) THEN 'RECEIPT_POSTED' ELSE 'CLOSED' END,
                        version = version + 1,
                        updated_at = now()
                    WHERE id = ? AND status = 'RECEIPT_ADJUSTED'
                    """, allowance.id()));
            appendEvent(allowance.id(), "RECEIPT_POSTED", actorUser, actorEmployee,
                    Map.of("approvedExcessQty", allowance.approvedExcessQty()));
            // 入库后若本异常仍有待退量（状态→RECEIPT_POSTED），通知采购/委外部门跟进退回；
            // 全部接收无需退回（状态→CLOSED）则不打扰，避免普通满额收货误发通知。
            if (hasPendingReturnTask(allowance.id())) {
                publish(EVENT_RECEIPT_POSTED, allowance.id(), allowance.version() + 1);
            }
        }
        refreshExpectationAccepted(orderType, receiptId);
    }

    /**
     * Symmetric inverse of {@link #recordApproval} on receipt reversal: subtracts the
     * previously posted excess (clamped at 0), reverts expectation ordered_qty, and returns
     * each RECEIPT_POSTED/CLOSED exception to RETURN_REQUIRED (return still owed) or CANCELED.
     */
    @Override
    @Transactional
    public void recordReversal(String rawOrderType, UUID receiptId) {
        tx.bind();
        String orderType = requireOrderType(rawOrderType);
        refreshExpectationAccepted(orderType, receiptId);
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        List<PostedAllowance> affected = jdbc.query("""
                SELECT id, order_item_id, expectation_item_id,
                       COALESCE(approved_excess_qty, 0) AS approved_excess_qty,
                       version
                FROM procurement_arrival_exceptions
                WHERE order_type = ? AND receipt_id = ?
                  AND status IN ('RECEIPT_POSTED', 'CLOSED')
                ORDER BY id
                FOR UPDATE
                """, (rs, rowNum) -> new PostedAllowance(
                        rs.getObject("id", UUID.class),
                        rs.getObject("order_item_id", UUID.class),
                        rs.getObject("expectation_item_id", UUID.class),
                        rs.getBigDecimal("approved_excess_qty"),
                        rs.getLong("version")),
                orderType, receiptId);
        String orderItemTable = PURCHASE.equals(orderType)
                ? "purchase_order_items" : "subcontract_order_items";
        for (PostedAllowance allowance : affected) {
            if (allowance.approvedExcessQty().signum() > 0) {
                requireChanged(jdbc.update("""
                        UPDATE %s
                        SET arrival_overage_posted_qty =
                            GREATEST(arrival_overage_posted_qty - ?, 0)
                        WHERE id = ?
                        """.formatted(orderItemTable),
                        allowance.approvedExcessQty(), allowance.orderItemId()));
                if (allowance.expectationItemId() != null) {
                    requireChanged(jdbc.update("""
                            UPDATE inbound_expectation_items
                            SET ordered_qty = ordered_qty - ?, updated_at = now()
                            WHERE id = ? AND ordered_qty > ?
                            """, allowance.approvedExcessQty(),
                            allowance.expectationItemId(),
                            allowance.approvedExcessQty()));
                }
            }
            requireChanged(jdbc.update("""
                    UPDATE procurement_arrival_exceptions exception_row
                    SET status = CASE WHEN EXISTS (
                            SELECT 1 FROM supplier_return_tasks return_task
                            WHERE return_task.arrival_exception_id = exception_row.id
                              AND return_task.status = 'PENDING_RETURN'
                        ) THEN 'RETURN_REQUIRED' ELSE 'CANCELED' END,
                        version = version + 1, updated_at = now()
                    WHERE id = ? AND status IN ('RECEIPT_POSTED', 'CLOSED')
                    """, allowance.id()));
            appendEvent(allowance.id(), "RECEIPT_REVERSED", actorUser, actorEmployee,
                    Map.of("approvedExcessQty", allowance.approvedExcessQty()));
        }
        refreshExpectationAccepted(orderType, receiptId);
    }

    @Override
    @Transactional
    public void cancelForOrderReversal(String rawOrderType, UUID orderId) {
        tx.bind();
        String orderType = requireOrderType(rawOrderType);
        Boolean openException = jdbc.queryForObject("""
                SELECT EXISTS(
                    SELECT 1 FROM procurement_arrival_exceptions
                    WHERE order_type = ? AND order_id = ?
                      AND status NOT IN ('CLOSED', 'CANCELED')
                )
                """, Boolean.class, orderType, orderId);
        if (Boolean.TRUE.equals(openException)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订货单仍有未处理的到货异常，禁止红冲；请先完成接收或供应商退回任务");
        }
        jdbc.update("""
                UPDATE inbound_expectations
                SET status = 'CANCELED', updated_at = now()
                WHERE order_type = ? AND order_id = ?
                  AND status IN ('OPEN', 'CLOSED')
                """, orderType, orderId);
    }

    @Override
    @Transactional
    public void refreshAfterReturn(
            String rawOrderType, Collection<UUID> rawOrderItemIds) {
        tx.bind();
        String orderType = requireOrderType(rawOrderType);
        List<UUID> orderItemIds = rawOrderItemIds == null
                ? List.of()
                : rawOrderItemIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (orderItemIds.isEmpty()) return;
        String orderItemTable = PURCHASE.equals(orderType)
                ? "purchase_order_items" : "subcontract_order_items";
        String placeholders = orderItemIds.stream()
                .map(ignored -> "?")
                .collect(java.util.stream.Collectors.joining(","));
        jdbc.update("""
                UPDATE inbound_expectation_items expectation_item
                SET accepted_qty = LEAST(
                        expectation_item.ordered_qty,
                        GREATEST(COALESCE(order_item.received_qty, 0)
                                 - COALESCE(order_item.returned_qty, 0)
                                 - COALESCE((
                                     SELECT SUM(rejection.failed_qty)
                                     FROM procurement_iqc_rejection_cases rejection
                                     WHERE rejection.receipt_type=expectation.order_type
                                       AND rejection.order_item_id=order_item.id
                                       AND rejection.is_deleted=FALSE
                                       AND rejection.return_recorded_at IS NOT NULL
                                       AND rejection.status IN(
                                           'RETURN_RECORDED','CREDIT_CONFIRMED',
                                           'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                                 ),0), 0)),
                    updated_at = now()
                FROM inbound_expectations expectation,
                     %s order_item
                WHERE expectation_item.expectation_id = expectation.id
                  AND expectation.order_type = ?
                  AND order_item.id = expectation_item.order_item_id
                  AND order_item.id IN (%s)
                """.formatted(orderItemTable, placeholders),
                prepend(orderType, orderItemIds));
        jdbc.update("""
                UPDATE inbound_expectations expectation
                SET status = CASE WHEN NOT EXISTS (
                        SELECT 1 FROM inbound_expectation_items item
                        WHERE item.expectation_id = expectation.id
                          AND item.accepted_qty < item.ordered_qty
                    ) THEN 'CLOSED' ELSE 'OPEN' END,
                    updated_at = now()
                WHERE expectation.order_type = ?
                  AND EXISTS (
                      SELECT 1 FROM inbound_expectation_items item
                      WHERE item.expectation_id = expectation.id
                        AND item.order_item_id IN (%s)
                  )
                """.formatted(placeholders),
                prepend(orderType, orderItemIds));
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('supplier_return_task:view')")
    public PageResponse<ArrivalExceptionTask> ownerTasks(
            String rawOrderType, int page, int size) {
        int safePage = safePage(page);
        int safeSize = safeSize(size);
        UUID actor = currentUser.requireId();
        String orderType = optionalOrderType(rawOrderType);
        List<Object> args = new ArrayList<>();
        args.add(actor);
        String typePredicate = "";
        if (orderType != null) {
            typePredicate = " AND exception.order_type = ?";
            args.add(orderType);
        }
        long total = countOwnerTasks(actor, orderType);
        args.add(safeSize);
        args.add((safePage - 1) * safeSize);
        List<ArrivalExceptionTask> items = queryExceptions(
                """
                return_task.owner_user_id = ?
                  AND return_task.status = 'PENDING_RETURN'
                """ + typePredicate,
                ActionScope.OWNER,
                "LIMIT ? OFFSET ?",
                args.toArray());
        return page(items, safePage, safeSize, total);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('supplier_return_task:view')")
    public long countOwnerTasks(String rawOrderType) {
        return countOwnerTasks(
                currentUser.requireId(), optionalOrderType(rawOrderType));
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('supplier_return_task:view')")
    public ArrivalExceptionTask ownerDetail(UUID id) {
        UUID actor = currentUser.requireId();
        List<ArrivalExceptionTask> rows = queryExceptions(
                "exception.id = ? AND return_task.owner_user_id = ?",
                ActionScope.OWNER,
                "",
                id,
                actor);
        if (rows.isEmpty()) {
            if (existsException(id)) {
                throw new ApiException(ErrorCode.FORBIDDEN, "该供应商退回任务未分配给当前用户");
            }
            throw new ApiException(ErrorCode.NOT_FOUND, "供应商退回任务不存在");
        }
        return rows.getFirst();
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_order_approval:view')")
    public PageResponse<ArrivalExceptionTask> financeTasks(int page, int size) {
        int safePage = safePage(page);
        int safeSize = safeSize(size);
        long total = countFinanceTasks();
        List<ArrivalExceptionTask> items = queryExceptions(
                "exception.status = 'PENDING_FINANCE'",
                ActionScope.FINANCE,
                "LIMIT ? OFFSET ?",
                safeSize,
                (safePage - 1) * safeSize);
        return page(items, safePage, safeSize, total);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_order_approval:view')")
    public long countFinanceTasks() {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_arrival_exceptions
                WHERE status = 'PENDING_FINANCE'
                """, Long.class);
        return count == null ? 0 : count;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_order_approval:view')")
    public ArrivalExceptionTask financeDetail(UUID id) {
        List<ArrivalExceptionTask> rows = queryExceptions(
                "exception.id = ?",
                ActionScope.FINANCE,
                "",
                id);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "到货异常任务不存在");
        }
        return rows.getFirst();
    }

    /**
     * Resolve a PENDING_FINANCE exception: APPROVE_ALL / APPROVE_CUSTOM / REJECT_EXCESS,
     * recomputing capacity from the live order state (not the detection-time snapshot),
     * trimming the draft receipt line to the accepted qty (deleting it if zero), and branching
     * to RECEIPT_ADJUSTED (something accepted) or RETURN_REQUIRED (all unaccepted, which also
     * requires a valid original-maker owner). A finance reason is mandatory unless REJECT_EXCESS.
     */
    @Transactional
    @PreAuthorize("hasAnyAuthority('finance_order_approval:approve','finance_order_approval:reject')")
    public ArrivalExceptionTask financeDecide(
            UUID id, ArrivalDecisionRequest request) {
        tx.bind();
        LockedException exception = lockException(id);
        requireEligibleReviewer();
        requireVersion(exception.version(), request.expectedVersion());
        if (!PENDING_FINANCE.equals(exception.status())) {
            throw concurrentChange();
        }

        List<ArrivalRow> rows = loadArrivalRows(
                exception.orderType(), exception.receiptId());
        CapacityAtLine capacity = capacityAt(rows, exception.receiptItemId());
        if (capacity == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "收货草稿明细已不存在，禁止在来源不明时继续处理");
        }

        String decision = normalizeDecision(request.decision());
        requireDecisionAuthority(decision);
        BigDecimal declared = exception.declaredQty();
        BigDecimal detectionApprovedRemaining = exception.approvedRemainingQty();
        BigDecimal approvedRemaining = capacity.available()
                .min(capacity.row().declaredQty());
        BigDecimal requestedExcess =
                nonNegative(declared.subtract(approvedRemaining));
        String reason = normalizeFinanceReason(
                request.financeReason(), !"REJECT_EXCESS".equals(decision));
        BigDecimal approvedExcess = switch (decision) {
            case "APPROVE_ALL" -> requestedExcess;
            case "APPROVE_CUSTOM" -> requireCustomApprovedExcess(
                    request.customApprovedExcessQty(), requestedExcess);
            case "REJECT_EXCESS" -> BigDecimal.ZERO;
            default -> throw new IllegalStateException("unreachable decision");
        };
        BigDecimal accepted = approvedRemaining.add(approvedExcess).min(declared);
        BigDecimal unaccepted = nonNegative(declared.subtract(accepted));

        if (unaccepted.signum() > 0) {
            requireReturnOwner(exception.ownerUserId(), exception.ownerEmployeeId());
        }
        adjustDraftReceipt(exception.orderType(), capacity.row(), accepted);

        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        int changed = jdbc.update("""
                UPDATE procurement_arrival_exceptions
                SET approved_remaining_qty = ?,
                    approved_excess_qty = ?,
                    accepted_qty = ?,
                    unaccepted_qty = ?,
                    status = ?,
                    decision = ?,
                    finance_reason = ?,
                    decided_by_user_id = ?,
                    decided_by_employee_id = ?,
                    decided_at = now(),
                    version = version + 1,
                    updated_at = now()
                WHERE id = ? AND version = ? AND status = 'PENDING_FINANCE'
                """,
                approvedRemaining,
                approvedExcess,
                accepted,
                unaccepted,
                accepted.signum() > 0 ? RECEIPT_ADJUSTED : RETURN_REQUIRED,
                decision,
                reason,
                actorUser,
                actorEmployee,
                id,
                request.expectedVersion());
        requireChanged(changed);

        if (unaccepted.signum() > 0) {
            upsertReturnTask(exception, unaccepted);
            publish(EVENT_RETURN_REQUIRED, id, request.expectedVersion() + 1);
        } else {
            cancelReturnTask(id);
        }

        Map<String, Object> snapshot = new LinkedHashMap<>();
        snapshot.put("decision", decision);
        snapshot.put("declaredQty", declared);
        snapshot.put("detectionApprovedRemainingQty", detectionApprovedRemaining);
        snapshot.put("decisionApprovedRemainingQty", approvedRemaining);
        snapshot.put("requestedExcessQty", requestedExcess);
        snapshot.put("approvedExcessQty", approvedExcess);
        snapshot.put("acceptedQty", accepted);
        snapshot.put("unacceptedQty", unaccepted);
        snapshot.put("unitPrice", exception.unitPrice());
        snapshot.put("declaredAmountOriginal", exception.declaredAmountOriginal());
        snapshot.put("declaredAmountLocal", exception.declaredAmountLocal());
        if (reason != null) {
            snapshot.put("financeReason", reason);
        }
        appendEvent(id, "FINANCE_DECIDED", actorUser, actorEmployee, snapshot);
        publish(EVENT_DECIDED, id, request.expectedVersion() + 1);
        return financeDetail(id);
    }

    @Transactional
    @PreAuthorize("hasAuthority('supplier_return_task:complete')")
    public ArrivalExceptionTask completeReturn(
            UUID returnTaskId, ReturnCompletionRequest request) {
        tx.bind();
        LockedReturnTask task = lockReturnTask(returnTaskId);
        requireExactOwner(task.ownerUserId(), task.ownerEmployeeId());
        requireVersion(task.version(), request.expectedVersion());
        if (!"PENDING_RETURN".equals(task.status())) {
            throw concurrentChange();
        }
        String note = normalizeNote(request.completionNote());
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        int changed = jdbc.update("""
                UPDATE supplier_return_tasks
                SET status = 'COMPLETED',
                    completion_note = ?,
                    completed_at = now(),
                    completed_by_user_id = ?,
                    completed_by_employee_id = ?,
                    version = version + 1,
                    updated_at = now()
                WHERE id = ? AND version = ? AND status = 'PENDING_RETURN'
                """,
                note,
                actorUser,
                actorEmployee,
                returnTaskId,
                request.expectedVersion());
        requireChanged(changed);
        jdbc.update("""
                UPDATE procurement_arrival_exceptions
                SET status = CASE
                        WHEN status IN ('RETURN_REQUIRED', 'RECEIPT_POSTED') THEN 'CLOSED'
                        ELSE status
                    END,
                    version = version + 1,
                    updated_at = now()
                WHERE id = ?
                """, task.exceptionId());
        appendEvent(task.exceptionId(), "RETURN_COMPLETED", actorUser, actorEmployee,
                note == null ? Map.of() : Map.of("completionNote", note));
        publish(EVENT_RETURN_COMPLETED, task.exceptionId(), request.expectedVersion() + 1);
        return ownerDetail(task.exceptionId());
    }

    @Transactional(readOnly = true)
    public PageResponse<ArrivalExceptionTask> warehouseExceptions(
            int page, int size, String keyword, boolean includeHistory) {
        int safePage = safePage(page);
        int safeSize = safeSize(size);
        List<String> clauses = new ArrayList<>();
        List<Object> args = new ArrayList<>();
        clauses.add(includeHistory
                ? "exception.status IN ('CLOSED', 'CANCELED')"
                : "exception.status NOT IN ('CLOSED', 'CANCELED')");
        String trimmed = keyword == null ? "" : keyword.trim();
        if (!trimmed.isEmpty()) {
            String like = "%" + trimmed + "%";
            clauses.add("""
                    (CAST(exception.id AS TEXT) ILIKE ?
                     OR exception.order_bill_no_snapshot ILIKE ?
                     OR exception.receipt_bill_no_snapshot ILIKE ?
                     OR goods.name ILIKE ?
                     OR supplier.name ILIKE ?)
                    """);
            for (int i = 0; i < 5; i++) {
                args.add(like);
            }
        }
        String where = String.join(" AND ", clauses);
        Long total = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_arrival_exceptions exception
                JOIN goods goods ON goods.id = exception.goods_id
                LEFT JOIN suppliers supplier ON supplier.id = exception.supplier_id
                """ + " WHERE " + where, Long.class, args.toArray());
        List<Object> queryArgs = new ArrayList<>(args);
        queryArgs.add(safeSize);
        queryArgs.add((safePage - 1) * safeSize);
        List<ArrivalExceptionTask> items = queryExceptions(
                where, ActionScope.NONE, "LIMIT ? OFFSET ?", queryArgs.toArray());
        // 价格脱敏（V302）：仓库视角无对应收货单价格权限时，金额快照置 null + priceMasked。
        items = items.stream().map(this::maskWarehousePrices).toList();
        return page(items, safePage, safeSize, total == null ? 0 : total);
    }

    @Transactional(readOnly = true)
    public ArrivalExceptionTask warehouseExceptionDetail(UUID id) {
        List<ArrivalExceptionTask> rows = queryExceptions(
                "exception.id = ?", ActionScope.NONE, "", id);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "到货异常任务不存在");
        }
        return maskWarehousePrices(rows.getFirst());
    }

    /**
     * 仓库侧到货异常价格脱敏（V302）：无该订货类型收货单价格权限时，
     * unitPrice/declared/excess 金额快照置 null 并打 priceMasked 标记（前端渲染 ***）。
     */
    private ArrivalExceptionTask maskWarehousePrices(ArrivalExceptionTask task) {
        boolean canView = PURCHASE.equals(task.orderType())
                ? priceMasker.canViewPurchaseReceipt()
                : priceMasker.canViewSubcontractReceipt();
        if (canView) {
            return task;
        }
        return new ArrivalExceptionTask(
                task.id(), task.orderType(), task.receiptId(), task.receiptItemId(),
                task.receiptBillNo(), task.orderId(), task.orderItemId(),
                task.orderBillNo(), task.supplierName(), task.warehouseName(),
                task.goodsCode(), task.goodsName(), task.colorName(), task.unitName(),
                task.declaredQty(), task.approvedRemainingQty(),
                null, null, null, null,
                task.requestedExcessQty(), task.approvedExcessQty(),
                task.financeAssigneeUserId(), task.financeAssigneeEmployeeId(),
                task.financeAssigneeName(), task.detectedByEmployeeName(),
                task.financeReason(), task.acceptedQty(), task.unacceptedQty(),
                task.status(), task.decision(), task.version(),
                task.detectedAt(), task.decidedAt(), task.returnTask(),
                task.allowedActions(), true);
    }

    /**
     * 一键入库前置校验：仅「财务已定案且有待入库量」(RECEIPT_ADJUSTED) 的异常可一键入库。
     * 返回要审核入库的收货单定位；实际入库/立应付由各收货单 Service 的 approve 复用链路完成。
     */
    @Transactional
    public StockTarget requireStockableException(UUID id) {
        tx.bind();
        LockedException exception = lockException(id);
        if (!RECEIPT_ADJUSTED.equals(exception.status())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该到货异常当前状态不支持一键入库(需财务已定案且有待入库量)");
        }
        if (exception.receiptId() == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "到货异常未关联收货单，无法入库");
        }
        return new StockTarget(exception.orderType(), exception.receiptId());
    }

    /**
     * 一键入库（同一事务）：定案后收货单审核会按接受量改写明细价格/数量，
     * 触发 receipt_item 守卫（异常未 CLOSED 时禁改），因此本事务内打开
     * `app.procurement_arrival_decision` 会话开关（与财务定案 adjustDraftReceipt 同口径），
     * 再复用各收货单 Service.approve 完整链路（库存/AP/recordApproval 关单）。
     */
    @Transactional
    @PreAuthorize("hasAuthority('warehouse_inbound:stock_in')")
    public ArrivalExceptionTask stockInWithDecisionSession(
            UUID id, java.util.function.Consumer<StockTarget> approveAction) {
        StockTarget target = requireStockableException(id);
        jdbc.queryForObject(
                "SELECT set_config('app.procurement_arrival_decision', 'on', true)",
                String.class);
        approveAction.accept(target);
        return warehouseExceptionDetail(id);
    }

    @Transactional(readOnly = true)
    public long countWarehouseExceptions() {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_arrival_exceptions
                WHERE status NOT IN ('CLOSED', 'CANCELED')
                """, Long.class);
        return count == null ? 0 : count;
    }

    @Transactional(readOnly = true)
    public PageResponse<InboundExpectationTask> expectations(
            int page, int size, String orderType, String keyword) {
        int safePage = safePage(page);
        int safeSize = safeSize(size);
        // 类型筛选卡（全部/采购/委外）：空 = 全部；非法值 fail-closed。
        String normalizedType = normalizeOrderType(orderType);
        String trimmedKeyword = normalizeKeyword(keyword);
        long total = countExpectations(normalizedType, trimmedKeyword);
        String typeFilter =
                normalizedType.isEmpty() ? "" : " AND expectation.order_type = ?\n";
        List<Object> params = new ArrayList<>();
        if (!normalizedType.isEmpty()) {
            params.add(normalizedType);
        }
        String keywordFilter = "";
        if (!trimmedKeyword.isEmpty()) {
            keywordFilter = " AND " + expectationKeywordClause() + "\n";
            String like = "%" + trimmedKeyword + "%";
            for (int i = 0; i < EXPECTATION_KEYWORD_PARAMS; i++) {
                params.add(like);
            }
        }
        params.add(safeSize);
        params.add((safePage - 1) * safeSize);
        List<ExpectationHeader> headers = jdbc.query("""
                SELECT expectation.id, expectation.order_type, expectation.order_id,
                       expectation.bill_no_snapshot, expectation.supplier_id,
                       supplier.name AS supplier_name, expectation.warehouse_id,
                       warehouse.name AS warehouse_name, expectation.expected_date,
                       expectation.owner_employee_id, owner.full_name AS owner_name,
                       expectation.status,
                       COALESCE(SUM(item.ordered_qty), 0) AS ordered_qty,
                       COALESCE(SUM(item.accepted_qty), 0) AS accepted_qty,
                       COALESCE(SUM(CASE
                           WHEN expectation.order_type = 'SUBCONTRACT'
                           THEN (
                """ + currentReceivableQty("item") + """
                           )
                           ELSE GREATEST(item.ordered_qty - item.accepted_qty, 0)
                       END), 0) AS remaining_qty
                FROM inbound_expectations expectation
                JOIN inbound_expectation_items item
                  ON item.expectation_id = expectation.id
                LEFT JOIN suppliers supplier ON supplier.id = expectation.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id = expectation.warehouse_id
                LEFT JOIN employees owner ON owner.id = expectation.owner_employee_id
                WHERE (
                """ + warehouseWorkRemaining() + """
                  )
                  AND (
                """ + expectationVisible() + """
                  )
                """ + typeFilter + keywordFilter + """
                GROUP BY expectation.id, supplier.name, warehouse.name, owner.full_name
                ORDER BY expectation.expected_date NULLS LAST, expectation.created_at, expectation.id
                LIMIT ? OFFSET ?
                """, (rs, rowNum) -> new ExpectationHeader(
                        rs.getObject("id", UUID.class),
                        rs.getString("order_type"),
                        rs.getObject("order_id", UUID.class),
                        rs.getString("bill_no_snapshot"),
                        rs.getObject("supplier_id", UUID.class),
                        rs.getString("supplier_name"),
                        rs.getObject("warehouse_id", UUID.class),
                        rs.getString("warehouse_name"),
                        rs.getObject("expected_date", LocalDate.class),
                        rs.getObject("owner_employee_id", UUID.class),
                        rs.getString("owner_name"),
                        rs.getString("status"),
                        rs.getBigDecimal("ordered_qty"),
                        rs.getBigDecimal("accepted_qty"),
                        rs.getBigDecimal("remaining_qty")),
                params.toArray());
        Map<UUID, UUID> suggestedWarehouses = suggestedWarehouses(
                headers.stream().map(ExpectationHeader::id).toList());
        Map<UUID, String> suggestedNames = warehouseNames(suggestedWarehouses.values());
        // 已登记待审核的草稿收货单（恢复入口）：任务中心据此提供「继续送检」。
        Map<UUID, List<UUID>> draftReceipts = draftReceiptIds(headers);
        // 流水线步骤聚合：待品质放行的收货单数 / 未结到货异常数（超量待财务）。
        Map<UUID, Integer> pendingInspections = pendingInspectionReceiptCounts(headers);
        Map<UUID, Integer> openExceptions = openArrivalExceptionCounts(headers);
        List<InboundExpectationTask> items = headers.stream()
                .map(header -> {
                    UUID suggestedId = suggestedWarehouses.get(header.id());
                    // suggestedNames 为不可变 Map（MapN），get(null) 会 NPE：
                    // 无建议仓（如委外自建订货无分析来源）时必须短路。
                    String suggestedName =
                            suggestedId == null ? null : suggestedNames.get(suggestedId);
                    return expectationTask(
                            header, suggestedId, suggestedName,
                            draftReceipts.getOrDefault(header.id(), List.of()),
                            pendingInspections.getOrDefault(header.id(), 0),
                            openExceptions.getOrDefault(header.id(), 0));
                })
                .toList();
        return page(items, safePage, safeSize, total);
    }

    /** 仓库 id → 名称（建议入库仓库展示用）；空输入直接返回空表。 */
    private Map<UUID, String> warehouseNames(java.util.Collection<UUID> warehouseIds) {
        List<UUID> ids = warehouseIds.stream().distinct().toList();
        if (ids.isEmpty()) return Map.of();
        String placeholders = String.join(
                ", ", java.util.Collections.nCopies(ids.size(), "?"));
        Map<UUID, String> names = new HashMap<>();
        jdbc.query("SELECT id, name FROM warehouses WHERE id IN ("
                + placeholders + ")", rs -> {
            names.put(rs.getObject("id", UUID.class), rs.getString("name"));
        }, ids.toArray());
        return names;
    }

    /**
     * 建议入库仓库（V301 配套）：沿 订货明细 → 来源申请明细 → 计划前供给行动 →
     * 物料分析目标仓 回溯；该任务的明细只关联到一个有效分析仓时返回它，登记到货
     * 页据此预填并锁定，避免货入错仓导致分析齐套/品质放行后进度不刷新。
     * 无分析来源或关联到多个不同分析仓时返回 null（仓库照常手选）。
     */
    private Map<UUID, UUID> suggestedWarehouses(List<UUID> expectationIds) {
        if (expectationIds.isEmpty()) return Map.of();
        String placeholders = String.join(
                ", ", java.util.Collections.nCopies(expectationIds.size(), "?"));
        Map<UUID, UUID> result = new HashMap<>();
        jdbc.query("""
                SELECT item.expectation_id,
                       COUNT(DISTINCT analysis.warehouse_id) AS wh_count,
                       MIN(analysis.warehouse_id::text) AS only_wh
                FROM inbound_expectation_items item
                LEFT JOIN purchase_order_items purchase_item
                  ON purchase_item.id = item.order_item_id
                LEFT JOIN subcontract_order_items subcontract_item
                  ON subcontract_item.id = item.order_item_id
                LEFT JOIN preplan_supply_action_allocations allocation
                  ON allocation.external_item_id IN (
                      -- V463：订货行多来源锚定——合并行的每个来源申请行都参与建议仓回溯。
                      SELECT pis.request_item_id
                      FROM purchase_order_item_sources pis
                      WHERE pis.order_item_id = purchase_item.id
                      UNION
                      SELECT sis.application_item_id
                      FROM subcontract_order_item_sources sis
                      WHERE sis.order_item_id = subcontract_item.id)
                LEFT JOIN preplan_supply_actions action
                  ON action.id = allocation.action_id
                 AND action.status <> 'CANCELLED'
                LEFT JOIN production_material_analyses analysis
                  ON analysis.id = allocation.analysis_id
                 AND analysis.is_deleted = FALSE
                 AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                 AND analysis.warehouse_id IS NOT NULL
                WHERE item.expectation_id IN (%s)
                GROUP BY item.expectation_id
                """.formatted(placeholders), rs -> {
            if (rs.getLong("wh_count") == 1) {
                result.put(
                        rs.getObject("expectation_id", UUID.class),
                        UUID.fromString(rs.getString("only_wh")));
            }
        }, expectationIds.toArray());
        return result;
    }

    @Transactional(readOnly = true)
    public long countExpectations() {
        return countExpectations("", "");
    }

    /**
     * 每个预计到货任务当前挂着的草稿收货单（status=0 未删，按订货明细关联），整页一次
     * 批量查询（与 inflight 在途量同口径）。任务中心「已登记待审核」态据此给出
     * 「继续送检」恢复入口——登记人中途退出后一键完成停止的步骤，不再进采购模块。
     */
    private Map<UUID, List<UUID>> draftReceiptIds(List<ExpectationHeader> headers) {
        Map<UUID, List<UUID>> result = new HashMap<>();
        for (String orderType : List.of(PURCHASE, SUBCONTRACT)) {
            List<UUID> expectationIds = headers.stream()
                    .filter(header -> orderType.equals(header.orderType()))
                    .map(ExpectationHeader::id)
                    .toList();
            if (expectationIds.isEmpty()) continue;
            String receiptTable = PURCHASE.equals(orderType)
                    ? "purchase_receipts" : "subcontract_receipts";
            String receiptItemTable = PURCHASE.equals(orderType)
                    ? "purchase_receipt_items" : "subcontract_receipt_items";
            String placeholders = String.join(
                    ", ", java.util.Collections.nCopies(expectationIds.size(), "?"));
            jdbc.query("""
                    SELECT DISTINCT item.expectation_id, receipt.id, receipt.created_at
                    FROM inbound_expectation_items item
                    JOIN %s receipt_item ON receipt_item.order_item_id = item.order_item_id
                    JOIN %s receipt ON receipt.id = receipt_item.receipt_id
                    WHERE item.expectation_id IN (%s)
                      AND receipt.status = 0 AND receipt.is_deleted = FALSE
                    ORDER BY receipt.created_at, receipt.id
                    """.formatted(receiptItemTable, receiptTable, placeholders), rs -> {
                result.computeIfAbsent(
                                rs.getObject("expectation_id", UUID.class),
                                ignored -> new ArrayList<>())
                        .add(rs.getObject("id", UUID.class));
            }, expectationIds.toArray());
        }
        return result;
    }

    /**
     * 每个任务的「待品质放行」收货单张数：已审核收货单中仍有 PENDING/PARTIAL 待检明细
     * 的（IQC 未放行完，货在待检隔离、未进可用库存）。任务卡据此显示「待品质检验」步骤。
     */
    private Map<UUID, Integer> pendingInspectionReceiptCounts(List<ExpectationHeader> headers) {
        Map<UUID, Integer> result = new HashMap<>();
        for (String orderType : List.of(PURCHASE, SUBCONTRACT)) {
            List<UUID> expectationIds = headers.stream()
                    .filter(header -> orderType.equals(header.orderType()))
                    .map(ExpectationHeader::id)
                    .toList();
            if (expectationIds.isEmpty()) continue;
            String receiptTable = PURCHASE.equals(orderType)
                    ? "purchase_receipts" : "subcontract_receipts";
            String receiptItemTable = PURCHASE.equals(orderType)
                    ? "purchase_receipt_items" : "subcontract_receipt_items";
            String placeholders = String.join(
                    ", ", java.util.Collections.nCopies(expectationIds.size(), "?"));
            jdbc.query("""
                    SELECT item.expectation_id, COUNT(DISTINCT receipt.id)
                    FROM inbound_expectation_items item
                    JOIN %s receipt_item ON receipt_item.order_item_id = item.order_item_id
                    JOIN %s receipt ON receipt.id = receipt_item.receipt_id
                      AND receipt.status = 1 AND receipt.is_deleted = FALSE
                    JOIN procurement_inspection_items inspection
                      ON inspection.receipt_item_id = receipt_item.id
                     AND inspection.receipt_type = ?
                     AND inspection.status IN ('PENDING','PARTIAL')
                    WHERE item.expectation_id IN (%s)
                    GROUP BY item.expectation_id
                    """.formatted(receiptItemTable, receiptTable, placeholders), rs -> {
                result.put(
                        rs.getObject("expectation_id", UUID.class),
                        rs.getInt(2));
            }, prepend(orderType, expectationIds));
        }
        return result;
    }

    /** 每个任务的未结到货异常数（超量被隔离，待财务定案）：任务卡据此显示「超量待财务」。 */
    private Map<UUID, Integer> openArrivalExceptionCounts(List<ExpectationHeader> headers) {
        if (headers.isEmpty()) return Map.of();
        List<UUID> expectationIds = headers.stream()
                .map(ExpectationHeader::id)
                .toList();
        String placeholders = String.join(
                ", ", java.util.Collections.nCopies(expectationIds.size(), "?"));
        Map<UUID, Integer> result = new HashMap<>();
        jdbc.query("""
                SELECT item.expectation_id, COUNT(DISTINCT exception.id)
                FROM inbound_expectation_items item
                JOIN procurement_arrival_exceptions exception
                  ON exception.order_item_id = item.order_item_id
                WHERE item.expectation_id IN (%s)
                  AND exception.status NOT IN ('CLOSED', 'CANCELED')
                GROUP BY item.expectation_id
                """.formatted(placeholders), rs -> {
            result.put(
                    rs.getObject("expectation_id", UUID.class),
                    rs.getInt(2));
        }, expectationIds.toArray());
        return result;
    }

    /** 预计到货任务计数：类型 + 关键字（单号/供应商/货品编码或名称）双条件；口径与列表一致
     * （仅保留仓库仍有活干的 OPEN 任务——见 warehouseWorkRemaining）。 */
    private long countExpectations(String orderType, String keyword) {
        String normalizedType = normalizeOrderType(orderType);
        StringBuilder sql = new StringBuilder("""
                SELECT COUNT(*) FROM inbound_expectations expectation
                WHERE (%s)
                  AND (%s)
                """.formatted(warehouseWorkRemaining(), expectationVisible()));
        List<Object> args = new ArrayList<>();
        if (!normalizedType.isEmpty()) {
            sql.append(" AND expectation.order_type = ?");
            args.add(normalizedType);
        }
        if (!keyword.isEmpty()) {
            sql.append(" AND ").append(expectationKeywordClause());
            String like = "%" + keyword + "%";
            for (int i = 0; i < EXPECTATION_KEYWORD_PARAMS; i++) {
                args.add(like);
            }
        }
        Long count = jdbc.queryForObject(sql.toString(), Long.class, args.toArray());
        return count == null ? 0 : count;
    }

    /** 预计到货按订货类型计数（顶部类型筛选卡口径：与列表同口径，不受当前筛选影响）。 */
    @Transactional(readOnly = true)
    public Map<String, Long> countExpectationsByType() {
        Map<String, Long> counts = new LinkedHashMap<>();
        jdbc.query("""
                SELECT order_type, COUNT(*)
                FROM inbound_expectations expectation
                WHERE (%s)
                  AND (%s)
                GROUP BY order_type
                """.formatted(warehouseWorkRemaining(), expectationVisible()), (rs) -> {
            counts.put(rs.getString(1), rs.getLong(2));
        });
        return counts;
    }

    /** 订货类型筛选值：空 = 全部；只允许 PURCHASE/SUBCONTRACT，其余 fail-closed。 */
    private static String normalizeOrderType(String orderType) {
        String normalized = orderType == null ? "" : orderType.strip().toUpperCase();
        return switch (normalized) {
            case "", PURCHASE, SUBCONTRACT -> normalized;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货类型无效");
        };
    }

    /** 搜索关键字：trim，超长截断（防御，正常前端输入远短于此）。 */
    private static String normalizeKeyword(String keyword) {
        if (keyword == null) return "";
        String trimmed = keyword.trim();
        return trimmed.length() > 100 ? trimmed.substring(0, 100) : trimmed;
    }

    /**
     * 货品资料「学习」回写（仓库登记到货保存成功后调用）：把本次填写的库位号/物料系列/
     * 物料编码写回货品主档，下次登记自动带出；用户改过的值同样回写。
     * 规则：trim；空值跳过；goodsCode 仅在主档为空且不与他货重复时回填（编码是业务主键，
     * 仓库误输不得覆盖）；series/stockPlace 与主档不同才更新；已删除货品一律跳过。
     */
    @Transactional
    public Map<String, Integer> applyGoodsProfileHints(List<GoodsProfileHintRequest> hints) {
        tx.bind();
        if (hints == null || hints.isEmpty()) {
            return Map.of("updated", 0, "skipped", 0);
        }
        if (hints.size() > 200) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "单次回写不能超过 200 条");
        }
        // 同一货品重复出现时以最后一行为准（登记明细理论上不重复，防御去重）。
        Map<UUID, GoodsProfileHintRequest> byGoods = new LinkedHashMap<>();
        for (GoodsProfileHintRequest hint : hints) {
            if (hint == null || hint.goodsId() == null) {
                continue;
            }
            byGoods.put(hint.goodsId(), hint);
        }
        if (byGoods.isEmpty()) {
            return Map.of("updated", 0, "skipped", 0);
        }
        List<UUID> ids = List.copyOf(byGoods.keySet());
        String placeholders = String.join(
                ", ", java.util.Collections.nCopies(ids.size(), "?"));
        Map<UUID, GoodsMasterRow> masters = new HashMap<>();
        jdbc.query("SELECT id, code, series, stock_place FROM goods WHERE id IN ("
                + placeholders + ") AND is_deleted = FALSE", rs -> {
            masters.put(rs.getObject("id", UUID.class), new GoodsMasterRow(
                    rs.getString("code"),
                    rs.getString("series"),
                    rs.getString("stock_place")));
        }, ids.toArray());

        UUID actor = currentUser.requireId();
        int updated = 0;
        int skipped = 0;
        for (Map.Entry<UUID, GoodsProfileHintRequest> entry : byGoods.entrySet()) {
            GoodsMasterRow master = masters.get(entry.getKey());
            if (master == null) {
                skipped++;
                continue;
            }
            GoodsProfileHintRequest hint = entry.getValue();
            String code = normalizeHint(hint.goodsCode());
            String series = normalizeHint(hint.series());
            String stockPlace = normalizeHint(hint.stockPlace());

            List<String> assignments = new ArrayList<>(3);
            List<Object> args = new ArrayList<>(3);
            if (code != null
                    && (master.code() == null || master.code().isBlank())
                    && !codeTakenByOtherGoods(code, entry.getKey())) {
                assignments.add("code = ?");
                args.add(code);
            }
            if (series != null && !series.equals(master.series())) {
                assignments.add("series = ?");
                args.add(series);
            }
            if (stockPlace != null && !stockPlace.equals(master.stockPlace())) {
                assignments.add("stock_place = ?");
                args.add(stockPlace);
            }
            if (assignments.isEmpty()) {
                skipped++;
                continue;
            }
            args.add(actor);
            args.add(entry.getKey());
            jdbc.update("UPDATE goods SET " + String.join(", ", assignments)
                    + ", version = version + 1, updated_at = now(), updated_by = ?"
                    + " WHERE id = ? AND is_deleted = FALSE", args.toArray());
            updated++;
        }
        return Map.of("updated", updated, "skipped", skipped);
    }

    /** 编码是否已被其他未删除货品占用（回填 code 前查重，防止仓库误输污染业务主键）。 */
    private boolean codeTakenByOtherGoods(String code, UUID goodsId) {
        Boolean exists = jdbc.queryForObject("""
                SELECT EXISTS(
                    SELECT 1 FROM goods
                    WHERE code = ? AND id <> ? AND is_deleted = FALSE)
                """, Boolean.class, code, goodsId);
        return Boolean.TRUE.equals(exists);
    }

    private static String normalizeHint(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        return value.trim();
    }

    private InboundExpectationTask expectationTask(
            ExpectationHeader header, UUID suggestedWarehouseId, String suggestedWarehouseName,
            List<UUID> draftReceiptIds,
            int pendingInspectionReceipts, int openArrivalExceptions) {
        // 已登记待审核在途量：草稿（status=0 未删）收货单按订货明细汇总。
        // 审核(1)后该量转入 accepted_qty，红冲(-1)/作废(删)后不再计入——任务卡片据此
        // 展示「已登记待审核」并扣减可再登记量，防止审核前同一批到货被重复登记。
        String receiptTable = PURCHASE.equals(header.orderType())
                ? "purchase_receipts" : "subcontract_receipts";
        String receiptItemTable = PURCHASE.equals(header.orderType())
                ? "purchase_receipt_items" : "subcontract_receipt_items";
        List<InboundExpectationItem> baseItems = jdbc.query(("""
                SELECT item.id, item.order_item_id, item.line_no,
                       item.goods_id, goods.code AS goods_code,
                       goods.name AS goods_name,
                       goods.series AS goods_series,
                       goods.stock_place AS goods_stock_place,
                       item.color_id,
                       color.name AS color_name, item.unit_id,
                       unit.name AS unit_name,
                       goods.unit_id AS base_unit_id,
                       base_unit.name AS base_unit_name,
                       item.unit_rate,
                       -- 2026-08-18 起不再向仓库端返回订货单价：价格对仓库不可见，
                       -- 收货审核时服务端按订货明细权威回填金额。
                       NULL AS unit_price,
                       item.ordered_qty, item.accepted_qty,
                       CASE WHEN expectation.order_type = 'SUBCONTRACT'
                            THEN (
                """ + currentReceivableQty("item") + """
                            )
                            ELSE GREATEST(item.ordered_qty-item.accepted_qty,0)
                       END AS remaining_qty,
                       COALESCE(inflight.registered_qty, 0) AS registered_qty,
                       item.expected_date
                FROM inbound_expectation_items item
                JOIN inbound_expectations expectation
                  ON expectation.id = item.expectation_id
                JOIN goods goods ON goods.id = item.goods_id
                LEFT JOIN colors color ON color.id = item.color_id
                LEFT JOIN units unit ON unit.id = item.unit_id
                LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                LEFT JOIN (
                    SELECT receipt_item.order_item_id,
                           SUM(receipt_item.qty) AS registered_qty
                    FROM %s receipt_item
                    JOIN %s receipt ON receipt.id = receipt_item.receipt_id
                    WHERE receipt.status = 0 AND receipt.is_deleted = FALSE
                      AND receipt_item.order_item_id IS NOT NULL
                    GROUP BY receipt_item.order_item_id
                ) inflight ON inflight.order_item_id = item.order_item_id
                WHERE item.expectation_id = ?
                  AND (expectation.order_type <> 'SUBCONTRACT'
                       OR (
                """ + subcontractItemVisible("item") + """
                       ))
                ORDER BY item.line_no NULLS LAST, item.id
                """).formatted(receiptItemTable, receiptTable),
                (rs, rowNum) -> new InboundExpectationItem(
                        rs.getObject("id", UUID.class),
                        rs.getObject("order_item_id", UUID.class),
                        (Integer) rs.getObject("line_no"),
                        rs.getObject("goods_id", UUID.class),
                        rs.getString("goods_code"),
                        rs.getString("goods_name"),
                        rs.getString("goods_series"),
                        rs.getString("goods_stock_place"),
                        rs.getObject("color_id", UUID.class),
                        rs.getString("color_name"),
                        rs.getObject("unit_id", UUID.class),
                        rs.getString("unit_name"),
                        rs.getObject("base_unit_id", UUID.class),
                        rs.getString("base_unit_name"),
                        rs.getBigDecimal("unit_rate"),
                        rs.getBigDecimal("unit_price"),
                        rs.getBigDecimal("ordered_qty"),
                        rs.getBigDecimal("accepted_qty"),
                        rs.getBigDecimal("remaining_qty"),
                        rs.getBigDecimal("registered_qty"),
                        rs.getObject("expected_date", LocalDate.class),
                        List.of()),
                header.id());
        Map<UUID, List<PreplanInboundAllocationReadPort.AllocationView>> expected =
                inboundAllocationRead.expectedForOrderItems(
                        header.orderType(),
                        baseItems.stream()
                                .map(item -> new PreplanInboundAllocationReadPort
                                        .OrderItemQuantity(
                                        item.orderItemId(),
                                        receivableBaseQty(
                                                item.remainingQty(),
                                                item.registeredQty(),
                                                item.unitRate())))
                                .toList());
        List<InboundExpectationItem> items = baseItems.stream().map(item ->
                new InboundExpectationItem(
                        item.id(), item.orderItemId(), item.lineNo(), item.goodsId(),
                        item.goodsCode(), item.goodsName(), item.goodsSeries(),
                        item.goodsStockPlace(), item.colorId(), item.colorName(),
                        item.unitId(), item.unitName(), item.baseUnitId(),
                        item.baseUnitName(), item.unitRate(), item.unitPrice(),
                        item.orderedQty(), item.acceptedQty(), item.remainingQty(),
                        item.registeredQty(), item.expectedDate(),
                        expected.getOrDefault(item.orderItemId(), List.of()).stream()
                                .map(ProcurementArrivalControlService::toInboundAllocation)
                                .toList())).toList();
        BigDecimal registeredQty = items.stream()
                .map(InboundExpectationItem::registeredQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal remainingQty = nonNegative(header.remainingQty());
        boolean canCreateReceipt = "OPEN".equals(header.status())
                && remainingQty.compareTo(registeredQty) > 0
                && currentUser.get().map(user -> user.isSuperAdmin()
                        || user.getAuthorities().stream().anyMatch(authority ->
                        "warehouse_inbound:stock_in".equals(authority.getAuthority())))
                        .orElse(false);
        return new InboundExpectationTask(
                header.id(),
                header.orderType(),
                header.orderId(),
                header.billNo(),
                header.supplierId(),
                header.supplierName(),
                header.warehouseId(),
                header.warehouseName(),
                suggestedWarehouseId,
                suggestedWarehouseName,
                header.expectedDate(),
                header.ownerEmployeeId(),
                header.ownerEmployeeName(),
                header.status(),
                header.orderedQty(),
                header.acceptedQty(),
                remainingQty,
                registeredQty,
                items,
                canCreateReceipt
                        ? List.of("PURCHASE".equals(header.orderType())
                                ? "CREATE_PURCHASE_RECEIPT"
                                : "CREATE_SUBCONTRACT_RECEIPT")
                        : List.of(),
                draftReceiptIds,
                pendingInspectionReceipts,
                openArrivalExceptions);
    }

    private static InboundAllocation toInboundAllocation(
            PreplanInboundAllocationReadPort.AllocationView value) {
        return new InboundAllocation(
                value.passEventId(), value.stockInBatchItemId(), value.kind(),
                value.qty(), value.actualWarehouseId(), value.actualWarehouseName(),
                value.targetWarehouseId(), value.targetWarehouseName(),
                value.intendedWarehouseNames(), value.warehouseMatches(),
                value.analysisId(), value.analysisMaterialId(),
                value.productCode(), value.productName(), value.sourceLabel(),
                value.planId(), value.planNo(), value.executionSegmentId(),
                value.executionSegmentCode(), value.workshopDepartmentId(),
                value.workshopName(), value.responsibleEmployeeId(),
                value.responsibleEmployeeName(), value.formationStatus());
    }

    private List<ArrivalExceptionTask> queryExceptions(
            String whereClause,
            ActionScope actionScope,
            String tailClause,
            Object... args) {
        String sql = """
                SELECT exception.id, exception.order_type, exception.receipt_id,
                       exception.receipt_item_id, exception.receipt_bill_no_snapshot,
                       exception.order_id, exception.order_item_id,
                       exception.order_bill_no_snapshot, supplier.name AS supplier_name,
                       warehouse.name AS warehouse_name, goods.code AS goods_code,
                       goods.name AS goods_name, color.name AS color_name,
                       unit.name AS unit_name, exception.declared_qty,
                       exception.approved_remaining_qty,
                       exception.unit_price_snapshot,
                       exception.declared_amount_original_snapshot,
                       exception.declared_amount_local_snapshot,
                       exception.excess_amount_local_snapshot,
                       exception.approved_excess_qty,
                       exception.finance_assignee_user_id,
                       exception.finance_assignee_employee_id,
                       exception.finance_assignee_name_snapshot,
                       detector.full_name AS detected_by_employee_name,
                       exception.finance_reason,
                       exception.accepted_qty, exception.unaccepted_qty,
                       exception.status, exception.decision,
                       exception.version, exception.detected_at, exception.decided_at,
                       return_task.id AS return_task_id, return_task.qty AS return_qty,
                       return_task.status AS return_status,
                       return_task.version AS return_version,
                       return_task.completion_note, return_task.completed_at
                FROM procurement_arrival_exceptions exception
                LEFT JOIN suppliers supplier ON supplier.id = exception.supplier_id
                LEFT JOIN warehouses warehouse ON warehouse.id = exception.warehouse_id
                JOIN goods goods ON goods.id = exception.goods_id
                LEFT JOIN colors color ON color.id = exception.color_id
                LEFT JOIN units unit ON unit.id = exception.unit_id
                LEFT JOIN employees detector
                  ON detector.id = exception.detected_by_employee_id
                LEFT JOIN supplier_return_tasks return_task
                  ON return_task.arrival_exception_id = exception.id
                """ + " WHERE " + whereClause
                + " ORDER BY exception.detected_at, exception.id " + tailClause;
        return jdbc.query(sql, (rs, rowNum) -> {
            SupplierReturnTask returnTask = rs.getObject("return_task_id") == null
                    ? null
                    : new SupplierReturnTask(
                            rs.getObject("return_task_id", UUID.class),
                            rs.getBigDecimal("return_qty"),
                            rs.getString("return_status"),
                            rs.getLong("return_version"),
                            rs.getString("completion_note"),
                            rs.getObject("completed_at", OffsetDateTime.class));
            List<String> actions = new ArrayList<>(3);
            String status = rs.getString("status");
            if (actionScope == ActionScope.FINANCE
                    && PENDING_FINANCE.equals(status)) {
                actions.add("APPROVE_ALL");
                actions.add("APPROVE_CUSTOM");
                actions.add("REJECT_EXCESS");
            }
            if (actionScope == ActionScope.OWNER
                    && returnTask != null
                    && "PENDING_RETURN".equals(returnTask.status())) {
                actions.add("COMPLETE_RETURN");
            }
            BigDecimal declared = rs.getBigDecimal("declared_qty");
            BigDecimal approvedRemaining =
                    rs.getBigDecimal("approved_remaining_qty");
            return new ArrivalExceptionTask(
                    rs.getObject("id", UUID.class),
                    rs.getString("order_type"),
                    rs.getObject("receipt_id", UUID.class),
                    rs.getObject("receipt_item_id", UUID.class),
                    rs.getString("receipt_bill_no_snapshot"),
                    rs.getObject("order_id", UUID.class),
                    rs.getObject("order_item_id", UUID.class),
                    rs.getString("order_bill_no_snapshot"),
                    rs.getString("supplier_name"),
                    rs.getString("warehouse_name"),
                    rs.getString("goods_code"),
                    rs.getString("goods_name"),
                    rs.getString("color_name"),
                    rs.getString("unit_name"),
                    declared,
                    approvedRemaining,
                    rs.getBigDecimal("unit_price_snapshot"),
                    rs.getBigDecimal("declared_amount_original_snapshot"),
                    rs.getBigDecimal("declared_amount_local_snapshot"),
                    rs.getBigDecimal("excess_amount_local_snapshot"),
                    nonNegative(declared.subtract(approvedRemaining)),
                    rs.getBigDecimal("approved_excess_qty"),
                    rs.getObject("finance_assignee_user_id", UUID.class),
                    rs.getObject("finance_assignee_employee_id", UUID.class),
                    rs.getString("finance_assignee_name_snapshot"),
                    rs.getString("detected_by_employee_name"),
                    rs.getString("finance_reason"),
                    rs.getBigDecimal("accepted_qty"),
                    rs.getBigDecimal("unaccepted_qty"),
                    status,
                    rs.getString("decision"),
                    rs.getLong("version"),
                    rs.getObject("detected_at", OffsetDateTime.class),
                    rs.getObject("decided_at", OffsetDateTime.class),
                    returnTask,
                    actions,
                    false);
        }, args);
    }

    private List<ArrivalRow> loadArrivalRows(String orderType, UUID receiptId) {
        String sql = "PURCHASE".equals(orderType) ? purchaseArrivalSql() : subcontractArrivalSql();
        return jdbc.query(sql, (rs, rowNum) -> new ArrivalRow(
                rs.getObject("receipt_id", UUID.class),
                rs.getObject("receipt_item_id", UUID.class),
                rs.getString("receipt_bill_no"),
                rs.getObject("order_id", UUID.class),
                rs.getObject("order_item_id", UUID.class),
                rs.getString("order_bill_no"),
                rs.getObject("expectation_id", UUID.class),
                rs.getObject("expectation_item_id", UUID.class),
                rs.getObject("supplier_id", UUID.class),
                rs.getObject("warehouse_id", UUID.class),
                rs.getObject("goods_id", UUID.class),
                rs.getObject("color_id", UUID.class),
                rs.getObject("unit_id", UUID.class),
                rs.getBigDecimal("unit_price"),
                rs.getBigDecimal("amount_original"),
                rs.getBigDecimal("amount_local"),
                rs.getBigDecimal("declared_qty"),
                rs.getBigDecimal("order_qty"),
                rs.getBigDecimal("received_qty"),
                rs.getBigDecimal("returned_qty"),
                rs.getBigDecimal("finance_approved_qty"),
                rs.getObject("owner_user_id", UUID.class),
                rs.getObject("owner_employee_id", UUID.class),
                rs.getString("owner_name")), receiptId);
    }

    private String purchaseArrivalSql() {
        return arrivalSql(
                "purchase_receipts",
                "purchase_receipt_items",
                "purchase_order_items",
                "purchase_orders",
                "PURCHASE");
    }

    private String subcontractArrivalSql() {
        return arrivalSql(
                "subcontract_receipts",
                "subcontract_receipt_items",
                "subcontract_order_items",
                "subcontract_orders",
                "SUBCONTRACT");
    }

    private String arrivalSql(
            String receiptTable,
            String receiptItemTable,
            String orderItemTable,
            String orderTable,
            String orderType) {
        return """
                SELECT receipt.id AS receipt_id,
                       receipt_item.id AS receipt_item_id,
                       receipt.bill_no AS receipt_bill_no,
                       procurement_order.id AS order_id,
                       order_item.id AS order_item_id,
                       procurement_order.bill_no AS order_bill_no,
                       expectation.id AS expectation_id,
                       expectation_item.id AS expectation_item_id,
                       receipt.supplier_id, receipt.warehouse_id,
                       receipt_item.goods_id, receipt_item.color_id,
                       receipt_item.unit_id,
                       receipt_item.price AS unit_price,
                       receipt_item.amount_original,
                       receipt_item.amount_local,
                       receipt_item.qty AS declared_qty,
                       order_item.qty AS order_qty,
                       COALESCE(order_item.received_qty, 0) AS received_qty,
                       COALESCE(order_item.returned_qty, 0) AS returned_qty,
                       CASE WHEN expectation.id IS NULL
                            THEN order_item.qty
                                 + COALESCE(order_item.arrival_overage_posted_qty, 0)
                            ELSE expectation_item.ordered_qty
                       END AS finance_approved_qty,
                       COALESCE(maker_owner.user_id,
                                creator_owner.user_id,
                                purchaser_owner.user_id) AS owner_user_id,
                       COALESCE(maker_owner.employee_id,
                                creator_owner.employee_id,
                                purchaser_owner.employee_id) AS owner_employee_id,
                       COALESCE(maker_owner.full_name,
                                creator_owner.full_name,
                                purchaser_owner.full_name) AS owner_name
                FROM %s receipt_item
                JOIN %s receipt ON receipt.id = receipt_item.receipt_id
                JOIN %s order_item ON order_item.id = receipt_item.order_item_id
                JOIN %s procurement_order ON procurement_order.id = order_item.order_id
                LEFT JOIN inbound_expectations expectation
                  ON expectation.order_type = '%s'
                 AND expectation.order_id = procurement_order.id
                LEFT JOIN inbound_expectation_items expectation_item
                  ON expectation_item.expectation_id = expectation.id
                 AND expectation_item.order_item_id = order_item.id
                LEFT JOIN LATERAL (
                    SELECT account.id AS user_id, employee.id AS employee_id,
                           employee.full_name
                    FROM users account
                    JOIN employees employee ON employee.id = account.employee_id
                    WHERE account.employee_id = procurement_order.maker_id
                      AND account.is_deleted = FALSE
                      AND account.status = 'active'
                      AND employee.is_deleted = FALSE
                      AND employee.status <> 'resigned'
                    ORDER BY account.id
                    LIMIT 1
                ) maker_owner ON TRUE
                LEFT JOIN LATERAL (
                    SELECT account.id AS user_id, employee.id AS employee_id,
                           employee.full_name
                    FROM users account
                    JOIN employees employee ON employee.id = account.employee_id
                    WHERE account.id = procurement_order.created_by
                      AND account.is_deleted = FALSE
                      AND account.status = 'active'
                      AND employee.is_deleted = FALSE
                      AND employee.status <> 'resigned'
                    LIMIT 1
                ) creator_owner ON TRUE
                LEFT JOIN LATERAL (
                    SELECT account.id AS user_id, employee.id AS employee_id,
                           employee.full_name
                    FROM users account
                    JOIN employees employee ON employee.id = account.employee_id
                    WHERE account.employee_id = procurement_order.purchaser_id
                      AND account.is_deleted = FALSE
                      AND account.status = 'active'
                      AND employee.is_deleted = FALSE
                      AND employee.status <> 'resigned'
                    ORDER BY account.id
                    LIMIT 1
                ) purchaser_owner ON TRUE
                WHERE receipt.id = ?
                  AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                  AND receipt.status = 0
                  AND COALESCE(receipt_item.is_deleted, FALSE) = FALSE
                  AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                  AND COALESCE(procurement_order.is_deleted, FALSE) = FALSE
                  AND procurement_order.status = 1
                ORDER BY order_item.id, receipt_item.line_no NULLS LAST, receipt_item.id
                FOR UPDATE OF receipt, receipt_item, order_item, procurement_order
                """.formatted(
                receiptItemTable, receiptTable, orderItemTable, orderTable, orderType);
    }

    private int countReceiptItems(String orderType, UUID receiptId) {
        String table = "PURCHASE".equals(orderType)
                ? "purchase_receipt_items"
                : "subcontract_receipt_items";
        Integer count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM " + table
                        + " WHERE receipt_id = ? AND COALESCE(is_deleted, FALSE) = FALSE",
                Integer.class,
                receiptId);
        return count == null ? 0 : count;
    }

    private Map<UUID, ExistingException> existingExceptions(
            String orderType, UUID receiptId) {
        Map<UUID, ExistingException> result = new HashMap<>();
        jdbc.query("""
                SELECT id, receipt_item_id, declared_qty, accepted_qty,
                       status, version
                FROM procurement_arrival_exceptions
                WHERE order_type = ? AND receipt_id = ?
                FOR UPDATE
                """, rs -> {
                    ExistingException row = new ExistingException(
                            rs.getObject("id", UUID.class),
                            rs.getObject("receipt_item_id", UUID.class),
                            rs.getBigDecimal("declared_qty"),
                            rs.getBigDecimal("accepted_qty"),
                            rs.getString("status"),
                            rs.getLong("version"));
                    result.put(row.receiptItemId(), row);
                }, orderType, receiptId);
        return result;
    }

    /**
     * 其它收货单上、同一订货明细的未结(非 CLOSED/CANCELED)到货异常：order_item_id → 收货单号快照。
     * 用于审核时拦截「重复收货单」——见 {@link #validateBeforeApproval}。
     */
    private Map<UUID, String> siblingOpenExceptionReceipts(
            String orderType, UUID receiptId) {
        Map<UUID, String> result = new HashMap<>();
        jdbc.query("""
                SELECT order_item_id, receipt_bill_no_snapshot
                FROM procurement_arrival_exceptions
                WHERE order_type = ?
                  AND receipt_id <> ?
                  AND status NOT IN ('CLOSED', 'CANCELED')
                """, rs -> {
                    result.putIfAbsent(
                            rs.getObject("order_item_id", UUID.class),
                            rs.getString("receipt_bill_no_snapshot"));
                }, orderType, receiptId);
        return result;
    }

    private ExistingException registerException(
            ArrivalRow row,
            BigDecimal approvedRemaining,
            ExistingException existing) {
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        String orderType = requireOrderTypeFromRow(row);
        requireReviewerPoolAvailable();
        BigDecimal excessQty =
                nonNegative(row.declaredQty().subtract(approvedRemaining));
        BigDecimal excessAmountLocal = proportionalAmount(
                row.amountLocal(), excessQty, row.declaredQty());

        if (existing == null) {
            UUID id = UUID.randomUUID();
            jdbc.update("""
                    INSERT INTO procurement_arrival_exceptions(
                        id, order_type, receipt_id, receipt_item_id,
                        receipt_bill_no_snapshot, order_id, order_item_id,
                        order_bill_no_snapshot, expectation_id, expectation_item_id,
                        supplier_id, warehouse_id, goods_id, color_id, unit_id,
                        declared_qty, unit_price_snapshot,
                        declared_amount_original_snapshot,
                        declared_amount_local_snapshot,
                        excess_amount_local_snapshot,
                        approved_remaining_qty,
                        owner_user_id, owner_employee_id, owner_name_snapshot,
                        finance_assignee_user_id,
                        finance_assignee_employee_id,
                        finance_assignee_name_snapshot,
                        status, version,
                        detected_by_user_id, detected_by_employee_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                              ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                              'PENDING_FINANCE', 1, ?, ?)
                    """,
                    id,
                    orderType,
                    row.receiptId(),
                    row.receiptItemId(),
                    row.receiptBillNo(),
                    row.orderId(),
                    row.orderItemId(),
                    row.orderBillNo(),
                    row.expectationId(),
                    row.expectationItemId(),
                    row.supplierId(),
                    row.warehouseId(),
                    row.goodsId(),
                    row.colorId(),
                    row.unitId(),
                    row.declaredQty(),
                    row.unitPrice(),
                    row.amountOriginal(),
                    row.amountLocal(),
                    excessAmountLocal,
                    approvedRemaining,
                    row.ownerUserId(),
                    row.ownerEmployeeId(),
                    row.ownerName(),
                    null,
                    null,
                    null,
                    actorUser,
                    actorEmployee);
            Map<String, Object> snapshot = new LinkedHashMap<>();
            snapshot.put("declaredQty", row.declaredQty());
            snapshot.put("approvedRemainingQty", approvedRemaining);
            snapshot.put("requestedExcessQty", excessQty);
            putIfNotNull(snapshot, "unitPrice", row.unitPrice());
            putIfNotNull(snapshot, "declaredAmountOriginal", row.amountOriginal());
            putIfNotNull(snapshot, "declaredAmountLocal", row.amountLocal());
            putIfNotNull(snapshot, "excessAmountLocal", excessAmountLocal);
            appendEvent(id, "DETECTED", actorUser, actorEmployee, snapshot);
            publish(EVENT_DETECTED, id, 1);
            return new ExistingException(
                    id, row.receiptItemId(), row.declaredQty(), null,
                    PENDING_FINANCE, 1);
        }
        if (PENDING_FINANCE.equals(existing.status())) {
            return existing;
        }

        jdbc.update("""
                UPDATE procurement_arrival_exceptions
                SET declared_qty = ?,
                    unit_price_snapshot = ?,
                    declared_amount_original_snapshot = ?,
                    declared_amount_local_snapshot = ?,
                    excess_amount_local_snapshot = ?,
                    approved_remaining_qty = ?,
                    approved_excess_qty = NULL,
                    accepted_qty = NULL,
                    unaccepted_qty = NULL,
                    owner_user_id = ?,
                    owner_employee_id = ?,
                    owner_name_snapshot = ?,
                    finance_assignee_user_id = ?,
                    finance_assignee_employee_id = ?,
                    finance_assignee_name_snapshot = ?,
                    status = 'PENDING_FINANCE',
                    decision = NULL,
                    finance_reason = NULL,
                    decided_by_user_id = NULL,
                    decided_by_employee_id = NULL,
                    decided_at = NULL,
                    detected_by_user_id = ?,
                    detected_by_employee_id = ?,
                    detected_at = now(),
                    version = version + 1,
                    updated_at = now()
                WHERE id = ?
                """,
                row.declaredQty(),
                row.unitPrice(),
                row.amountOriginal(),
                row.amountLocal(),
                excessAmountLocal,
                approvedRemaining,
                row.ownerUserId(),
                row.ownerEmployeeId(),
                row.ownerName(),
                null,
                null,
                null,
                actorUser,
                actorEmployee,
                existing.id());
        Map<String, Object> snapshot = new LinkedHashMap<>();
        snapshot.put("declaredQty", row.declaredQty());
        snapshot.put("approvedRemainingQty", approvedRemaining);
        snapshot.put("requestedExcessQty", excessQty);
        appendEvent(existing.id(), "REDETECTED", actorUser, actorEmployee, snapshot);
        publish(EVENT_DETECTED, existing.id(), existing.version() + 1);
        return new ExistingException(
                existing.id(), existing.receiptItemId(), row.declaredQty(),
                null, PENDING_FINANCE, existing.version() + 1);
    }

    private String requireOrderTypeFromRow(ArrivalRow row) {
        return row.expectationId() == null
                ? inferOrderType(row.orderId())
                : jdbc.queryForObject(
                        "SELECT order_type FROM inbound_expectations WHERE id = ?",
                        String.class,
                        row.expectationId());
    }

    private String inferOrderType(UUID orderId) {
        Boolean purchase = jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM purchase_orders WHERE id = ?)
                """, Boolean.class, orderId);
        return Boolean.TRUE.equals(purchase) ? PURCHASE : SUBCONTRACT;
    }

    private BigDecimal approvedRemaining(ArrivalRow row,String orderType) {
        if (row.financeApprovedQty() == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "财务批准的预计到货明细缺失，禁止入库");
        }
        return nonNegative(row.financeApprovedQty()
                .add(zero(row.returnedQty()))
                .add(returnedIqcFailureQty(orderType,row.orderItemId()))
                .subtract(zero(row.receivedQty())));
    }

    private BigDecimal returnedIqcFailureQty(String orderType,UUID orderItemId) {
        return zero(jdbc.queryForObject("""
                SELECT COALESCE(SUM(failed_qty),0)
                FROM procurement_iqc_rejection_cases
                WHERE receipt_type=? AND order_item_id=? AND is_deleted=FALSE
                  AND return_recorded_at IS NOT NULL
                  AND status IN(
                      'RETURN_RECORDED','CREDIT_CONFIRMED',
                      'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                """,BigDecimal.class,orderType,orderItemId));
    }

    private CapacityAtLine capacityAt(List<ArrivalRow> rows, UUID receiptItemId) {
        Map<UUID, BigDecimal> base = new HashMap<>();
        Map<UUID, BigDecimal> allocated = new HashMap<>();
        for (ArrivalRow row : rows) {
            BigDecimal remaining = base.computeIfAbsent(
                    row.orderItemId(), ignored -> approvedRemaining(
                            row,requireOrderTypeFromRow(row)));
            BigDecimal before = allocated.getOrDefault(row.orderItemId(), BigDecimal.ZERO);
            BigDecimal available = nonNegative(remaining.subtract(before));
            if (row.receiptItemId().equals(receiptItemId)) {
                return new CapacityAtLine(row, available);
            }
            allocated.merge(row.orderItemId(), row.declaredQty().min(available), BigDecimal::add);
        }
        return null;
    }

    private void adjustDraftReceipt(
            String orderType, ArrivalRow row, BigDecimal acceptedQty) {
        jdbc.queryForObject(
                "SELECT set_config('app.procurement_arrival_decision', 'on', true)",
                String.class);
        String itemTable = "PURCHASE".equals(orderType)
                ? "purchase_receipt_items"
                : "subcontract_receipt_items";
        String receiptTable = "PURCHASE".equals(orderType)
                ? "purchase_receipts"
                : "subcontract_receipts";
        BigDecimal currentQty = row.declaredQty();
        if (acceptedQty.signum() == 0) {
            requireChanged(jdbc.update("""
                    DELETE FROM %s item
                    USING %s receipt
                    WHERE item.id = ?
                      AND receipt.id = item.receipt_id
                      AND receipt.status = 0
                      AND receipt.is_deleted = FALSE
                      AND item.is_deleted = FALSE
                    """.formatted(itemTable, receiptTable), row.receiptItemId()));
        } else {
            requireChanged(jdbc.update("""
                    UPDATE %s item
                    SET qty = ?,
                        amount_original = CASE WHEN amount_original IS NULL THEN NULL
                            ELSE round(amount_original * ? / NULLIF(?, 0), 4) END,
                        amount_local = CASE WHEN amount_local IS NULL THEN NULL
                            ELSE round(amount_local * ? / NULLIF(?, 0), 4) END,
                        weight = CASE WHEN weight IS NULL THEN NULL
                            ELSE round(weight * ? / NULLIF(?, 0), 4) END,
                        updated_at = now()
                    FROM %s receipt
                    WHERE item.id = ?
                      AND receipt.id = item.receipt_id
                      AND receipt.status = 0
                      AND receipt.is_deleted = FALSE
                      AND item.is_deleted = FALSE
                    """.formatted(itemTable, receiptTable),
                    acceptedQty,
                    acceptedQty,
                    currentQty,
                    acceptedQty,
                    currentQty,
                    acceptedQty,
                    currentQty,
                    row.receiptItemId()));
            if (SUBCONTRACT.equals(orderType)) {
                requireChanged(jdbc.update("""
                        UPDATE subcontract_receipt_items item
                        SET check_qty = CASE
                                WHEN check_qty IS NULL THEN NULL
                                ELSE LEAST(check_qty, ?)
                            END,
                            girth_qty = CASE
                                WHEN girth_qty IS NULL THEN NULL
                                ELSE round(girth_qty * ? / NULLIF(?, 0), 4)
                            END,
                            updated_at = now()
                        FROM subcontract_receipts receipt
                        WHERE item.id = ?
                          AND receipt.id = item.receipt_id
                          AND receipt.status = 0
                          AND receipt.is_deleted = FALSE
                          AND item.is_deleted = FALSE
                        """,
                        acceptedQty, acceptedQty, currentQty, row.receiptItemId()));
            }
        }
        requireChanged(jdbc.update("""
                UPDATE %s receipt
                SET total_original = COALESCE((
                        SELECT SUM(item.amount_original)
                        FROM %s item
                        WHERE item.receipt_id = receipt.id
                          AND COALESCE(item.is_deleted, FALSE) = FALSE
                    ), 0),
                    total_local = COALESCE((
                        SELECT SUM(item.amount_local)
                        FROM %s item
                        WHERE item.receipt_id = receipt.id
                          AND COALESCE(item.is_deleted, FALSE) = FALSE
                    ), 0),
                    is_deleted = NOT EXISTS (
                        SELECT 1 FROM %s item
                        WHERE item.receipt_id = receipt.id
                          AND COALESCE(item.is_deleted, FALSE) = FALSE
                    ),
                    deleted_at = CASE WHEN NOT EXISTS (
                        SELECT 1 FROM %s item
                        WHERE item.receipt_id = receipt.id
                          AND COALESCE(item.is_deleted, FALSE) = FALSE
                    ) THEN COALESCE(receipt.deleted_at, now())
                      ELSE receipt.deleted_at END,
                    updated_at = now()
                WHERE receipt.id = ?
                  AND receipt.status = 0
                  AND receipt.is_deleted = FALSE
                """.formatted(
                        receiptTable, itemTable, itemTable, itemTable, itemTable),
                row.receiptId()));
    }

    private void upsertReturnTask(
            LockedException exception, BigDecimal qty) {
        if (qty.signum() <= 0) {
            cancelReturnTask(exception.id());
            return;
        }
        jdbc.update("""
                INSERT INTO supplier_return_tasks(
                    id, arrival_exception_id, order_type, order_id, order_item_id,
                    receipt_id, receipt_item_id, owner_user_id, owner_employee_id,
                    qty, status, version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT (arrival_exception_id) DO UPDATE
                SET qty = EXCLUDED.qty,
                    status = EXCLUDED.status,
                    owner_user_id = EXCLUDED.owner_user_id,
                    owner_employee_id = EXCLUDED.owner_employee_id,
                    completion_note = NULL,
                    completed_at = NULL,
                    completed_by_user_id = NULL,
                    completed_by_employee_id = NULL,
                    version = supplier_return_tasks.version + 1,
                    updated_at = now()
                """,
                UUID.randomUUID(),
                exception.id(),
                exception.orderType(),
                exception.orderId(),
                exception.orderItemId(),
                exception.receiptId(),
                exception.receiptItemId(),
                exception.ownerUserId(),
                exception.ownerEmployeeId(),
                qty,
                "PENDING_RETURN");
    }

    private void cancelReturnTask(UUID exceptionId) {
        jdbc.update("""
                UPDATE supplier_return_tasks
                SET status = 'CANCELED', version = version + 1, updated_at = now(),
                    completed_at = NULL, completed_by_user_id = NULL,
                    completed_by_employee_id = NULL
                WHERE arrival_exception_id = ?
                  AND status = 'PENDING_RETURN'
                """, exceptionId);
    }

    private void refreshExpectationAccepted(String orderType, UUID receiptId) {
        String receiptItemTable = "PURCHASE".equals(orderType)
                ? "purchase_receipt_items"
                : "subcontract_receipt_items";
        String orderItemTable = "PURCHASE".equals(orderType)
                ? "purchase_order_items"
                : "subcontract_order_items";
        jdbc.update("""
                UPDATE inbound_expectation_items expectation_item
                SET accepted_qty = LEAST(
                        expectation_item.ordered_qty,
                        GREATEST(COALESCE(order_item.received_qty, 0)
                                 - COALESCE(order_item.returned_qty, 0)
                                 - COALESCE((
                                     SELECT SUM(rejection.failed_qty)
                                     FROM procurement_iqc_rejection_cases rejection
                                     WHERE rejection.receipt_type=expectation.order_type
                                       AND rejection.order_item_id=order_item.id
                                       AND rejection.is_deleted=FALSE
                                       AND rejection.return_recorded_at IS NOT NULL
                                       AND rejection.status IN(
                                           'RETURN_RECORDED','CREDIT_CONFIRMED',
                                           'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                                 ),0), 0)),
                    updated_at = now()
                FROM inbound_expectations expectation,
                     %s receipt_item,
                     %s order_item
                WHERE expectation_item.expectation_id = expectation.id
                  AND expectation.order_type = ?
                  AND receipt_item.receipt_id = ?
                  AND order_item.id = receipt_item.order_item_id
                  AND expectation_item.order_item_id = order_item.id
                """.formatted(receiptItemTable, orderItemTable), orderType, receiptId);
        jdbc.update("""
                UPDATE inbound_expectations expectation
                SET status = CASE WHEN NOT EXISTS (
                        SELECT 1 FROM inbound_expectation_items item
                        WHERE item.expectation_id = expectation.id
                          AND item.accepted_qty < item.ordered_qty
                    ) THEN 'CLOSED' ELSE 'OPEN' END,
                    updated_at = now()
                WHERE expectation.order_type = ?
                  AND EXISTS (
                      SELECT 1
                      FROM inbound_expectation_items item
                      JOIN %s receipt_item
                        ON receipt_item.order_item_id = item.order_item_id
                      WHERE item.expectation_id = expectation.id
                        AND receipt_item.receipt_id = ?
                  )
                """.formatted(receiptItemTable), orderType, receiptId);
    }

    private LockedException lockException(UUID id) {
        List<LockedException> rows = jdbc.query("""
                SELECT id, order_type, receipt_id, receipt_item_id,
                       order_id, order_item_id, declared_qty,
                       approved_remaining_qty, unit_price_snapshot,
                       declared_amount_original_snapshot,
                       declared_amount_local_snapshot,
                       owner_user_id, owner_employee_id,
                       finance_assignee_user_id,
                       finance_assignee_employee_id,
                       status, version
                FROM procurement_arrival_exceptions
                WHERE id = ?
                FOR UPDATE
                """, (rs, rowNum) -> new LockedException(
                        rs.getObject("id", UUID.class),
                        rs.getString("order_type"),
                        rs.getObject("receipt_id", UUID.class),
                        rs.getObject("receipt_item_id", UUID.class),
                        rs.getObject("order_id", UUID.class),
                        rs.getObject("order_item_id", UUID.class),
                        rs.getBigDecimal("declared_qty"),
                        rs.getBigDecimal("approved_remaining_qty"),
                        rs.getBigDecimal("unit_price_snapshot"),
                        rs.getBigDecimal("declared_amount_original_snapshot"),
                        rs.getBigDecimal("declared_amount_local_snapshot"),
                        rs.getObject("owner_user_id", UUID.class),
                        rs.getObject("owner_employee_id", UUID.class),
                        rs.getObject("finance_assignee_user_id", UUID.class),
                        rs.getObject("finance_assignee_employee_id", UUID.class),
                        rs.getString("status"),
                        rs.getLong("version")), id);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "到货异常任务不存在");
        }
        return rows.getFirst();
    }

    private LockedReturnTask lockReturnTask(UUID id) {
        List<LockedReturnTask> rows = jdbc.query("""
                SELECT return_task.id, return_task.arrival_exception_id,
                       return_task.owner_user_id, return_task.owner_employee_id,
                       return_task.status, return_task.version
                FROM supplier_return_tasks return_task
                WHERE return_task.id = ?
                FOR UPDATE
                """, (rs, rowNum) -> new LockedReturnTask(
                        rs.getObject("id", UUID.class),
                        rs.getObject("arrival_exception_id", UUID.class),
                        rs.getObject("owner_user_id", UUID.class),
                        rs.getObject("owner_employee_id", UUID.class),
                        rs.getString("status"),
                        rs.getLong("version")), id);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "供应商退回任务不存在");
        }
        return rows.getFirst();
    }

    private void requireExactOwner(UUID ownerUser, UUID ownerEmployee) {
        if (ownerUser == null
                || ownerEmployee == null
                || !ownerUser.equals(currentUser.requireId())
                || !ownerEmployee.equals(currentUser.requireEmployeeId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "该任务仅允许原下单人处理");
        }
    }

    private void requireReturnOwner(UUID ownerUser, UUID ownerEmployee) {
        if (ownerUser == null || ownerEmployee == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "无法确定有效的原下单人，禁止生成无人负责的供应商退回任务");
        }
        Boolean eligible = jdbc.queryForObject("""
                SELECT EXISTS(
                    SELECT 1
                    FROM users account
                    JOIN employees employee
                      ON employee.id = account.employee_id
                    WHERE account.id = ?
                      AND employee.id = ?
                      AND account.is_deleted = FALSE
                      AND account.status = 'active'
                      AND employee.is_deleted = FALSE
                      AND employee.status <> 'resigned'
                )
                """, Boolean.class, ownerUser, ownerEmployee);
        if (!Boolean.TRUE.equals(eligible)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "原下单人账号已停用或离职，禁止生成无人可处理的供应商退回任务");
        }
    }

    private void requireReviewerPoolAvailable() {
        if (reviewerEligibility.allEligible().isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "暂无持有审批权限的在职财务人员，禁止生成无人审批的到货异常");
        }
    }

    private void requireDecisionAuthority(String decision) {
        String permission = "REJECT_EXCESS".equals(decision)
                ? "finance_order_approval:reject"
                : "finance_order_approval:approve";
        boolean allowed = currentUser.get()
                .map(user -> user.isSuperAdmin() || user.getAuthorities().stream()
                        .anyMatch(authority -> permission.equals(authority.getAuthority())))
                .orElse(false);
        if (!allowed) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少该到货异常决定对应的批准或驳回权限");
        }
    }

    private void requireEligibleReviewer() {
        UUID actor = currentUser.requireId();
        reviewerEligibility.findEligible(actor).orElseThrow(() -> new ApiException(
                ErrorCode.FORBIDDEN,
                "仅财务审核组内且持有对应批准或驳回权限的人员可处理到货超量审批"));
    }

    private void bindReceiptAllowance(String orderType, UUID receiptId) {
        jdbc.queryForObject(
                "SELECT set_config('app.procurement_arrival_receipt_id', ?, true)",
                String.class,
                receiptId.toString());
        jdbc.queryForObject(
                "SELECT set_config('app.procurement_arrival_order_type', ?, true)",
                String.class,
                orderType);
    }

    private void appendEvent(
            UUID exceptionId,
            String eventType,
            UUID actorUser,
            UUID actorEmployee,
            Map<String, ?> snapshot) {
        jdbc.update("""
                INSERT INTO procurement_arrival_exception_events(
                    id, arrival_exception_id, event_type,
                    actor_user_id, actor_employee_id, event_snapshot
                ) VALUES (?, ?, ?, ?, ?, CAST(? AS jsonb))
                """,
                UUID.randomUUID(),
                exceptionId,
                eventType,
                actorUser,
                actorEmployee,
                json(snapshot));
    }

    /** 本异常是否存在尚未完成的供应商退回任务（决定入库后是否需要通知采购/委外跟进退回）。 */
    private boolean hasPendingReturnTask(UUID exceptionId) {
        Boolean exists = jdbc.queryForObject("""
                SELECT EXISTS(
                    SELECT 1 FROM supplier_return_tasks
                    WHERE arrival_exception_id = ? AND status = 'PENDING_RETURN')
                """, Boolean.class, exceptionId);
        return Boolean.TRUE.equals(exists);
    }

    private void publish(String eventType, UUID exceptionId, long version) {
        events.publishOnce(
                eventType,
                "PROCUREMENT_ARRIVAL_EXCEPTION",
                exceptionId,
                Map.of("version", version),
                eventType + ':' + exceptionId + ':' + version);
    }

    private long countOwnerTasks(UUID actor, String orderType) {
        String typePredicate = orderType == null ? "" : " AND exception.order_type = ?";
        List<Object> args = new ArrayList<>();
        args.add(actor);
        if (orderType != null) {
            args.add(orderType);
        }
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM supplier_return_tasks return_task
                JOIN procurement_arrival_exceptions exception
                  ON exception.id = return_task.arrival_exception_id
                WHERE return_task.owner_user_id = ?
                  AND return_task.status = 'PENDING_RETURN'
                """ + typePredicate, Long.class, args.toArray());
        return count == null ? 0 : count;
    }

    private long countFinanceTasks(UUID actor) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_arrival_exceptions
                WHERE finance_assignee_user_id = ?
                  AND status = 'PENDING_FINANCE'
                """, Long.class, actor);
        return count == null ? 0 : count;
    }

    private boolean existsException(UUID id) {
        Boolean exists = jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM procurement_arrival_exceptions WHERE id = ?)
                """, Boolean.class, id);
        return Boolean.TRUE.equals(exists);
    }

    private String json(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("到货异常事件快照无法序列化", error);
        }
    }

    private static String requireOrderType(String value) {
        String normalized = value == null ? "" : value.trim().toUpperCase();
        if (!PURCHASE.equals(normalized) && !SUBCONTRACT.equals(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "orderType 仅支持 PURCHASE 或 SUBCONTRACT");
        }
        return normalized;
    }

    private static String optionalOrderType(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        return requireOrderType(value);
    }

    private static String normalizeDecision(String value) {
        String normalized = value == null ? "" : value.trim().toUpperCase();
        if (!List.of(
                "APPROVE_ALL",
                "APPROVE_CUSTOM",
                "REJECT_EXCESS").contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "财务到货处理决定无效");
        }
        return normalized;
    }

    private static BigDecimal requireCustomApprovedExcess(
            BigDecimal requested, BigDecimal requestedExcess) {
        if (requested == null || requestedExcess == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "自定义批准超量必须大于 0 且小于本次请求超量");
        }
        BigDecimal normalized = requested.setScale(4, RoundingMode.HALF_UP);
        BigDecimal normalizedLimit =
                requestedExcess.setScale(4, RoundingMode.HALF_UP);
        if (normalizedLimit.signum() <= 0
                || normalized.signum() <= 0
                || normalized.compareTo(normalizedLimit) >= 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "自定义批准超量必须大于 0 且小于本次请求超量");
        }
        return normalized.stripTrailingZeros();
    }

    private static String normalizeFinanceReason(
            String value, boolean required) {
        if (value == null || value.isBlank()) {
            if (required) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "批准超量时必须填写财务审核理由");
            }
            return null;
        }
        String normalized = value.trim();
        if (normalized.length() > 1000) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "财务审核理由不能超过 1000 字");
        }
        return normalized;
    }

    private static BigDecimal proportionalAmount(
            BigDecimal amount, BigDecimal qty, BigDecimal declaredQty) {
        if (amount == null
                || qty == null
                || declaredQty == null
                || declaredQty.signum() == 0) {
            return null;
        }
        return amount.multiply(qty)
                .divide(declaredQty, 4, RoundingMode.HALF_UP);
    }

    private static void putIfNotNull(
            Map<String, Object> target, String key, Object value) {
        if (value != null) {
            target.put(key, value);
        }
    }

    private static String normalizeNote(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        String normalized = value.trim();
        if (normalized.length() > 1000) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "退回说明不能超过 1000 字");
        }
        return normalized;
    }

    private static void requireVersion(long actual, Long expected) {
        if (expected == null || expected < 1 || actual != expected) {
            throw concurrentChange();
        }
    }

    private static void requireChanged(int changed) {
        if (changed != 1) {
            throw concurrentChange();
        }
    }

    private static ApiException concurrentChange() {
        return new ApiException(
                ErrorCode.CONFLICT,
                "到货异常任务已被处理或版本已变化，请刷新后重试");
    }

    private static BigDecimal zero(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static BigDecimal nonNegative(BigDecimal value) {
        return value.signum() < 0 ? BigDecimal.ZERO : value;
    }

    static BigDecimal receivableBaseQty(
            BigDecimal remainingQty,
            BigDecimal registeredQty,
            BigDecimal unitRate) {
        return nonNegative(nonNegative(remainingQty)
                .subtract(nonNegative(registeredQty)))
                .multiply(unitRate == null ? BigDecimal.ONE : unitRate);
    }

    private static boolean sameQuantity(BigDecimal left, BigDecimal right) {
        return left != null && right != null && left.compareTo(right) == 0;
    }

    private static int safePage(int page) {
        return Math.max(1, page);
    }

    private static int safeSize(int size) {
        return Math.max(1, Math.min(size, 200));
    }

    private static <T> PageResponse<T> page(
            List<T> items, int page, int size, long total) {
        int totalPages = total == 0 ? 0 : (int) ((total + size - 1) / size);
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    private static Object[] prepend(Object first, List<?> rest) {
        Object[] values = new Object[rest.size() + 1];
        values[0] = first;
        for (int index = 0; index < rest.size(); index++) {
            values[index + 1] = rest.get(index);
        }
        return values;
    }

    private record ArrivalRow(
            UUID receiptId,
            UUID receiptItemId,
            String receiptBillNo,
            UUID orderId,
            UUID orderItemId,
            String orderBillNo,
            UUID expectationId,
            UUID expectationItemId,
            UUID supplierId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal unitPrice,
            BigDecimal amountOriginal,
            BigDecimal amountLocal,
            BigDecimal declaredQty,
            BigDecimal orderQty,
            BigDecimal receivedQty,
            BigDecimal returnedQty,
            BigDecimal financeApprovedQty,
            UUID ownerUserId,
            UUID ownerEmployeeId,
            String ownerName) {
    }

    private record ExistingException(
            UUID id,
            UUID receiptItemId,
            BigDecimal declaredQty,
            BigDecimal acceptedQty,
            String status,
            long version) {
    }

    private record LockedException(
            UUID id,
            String orderType,
            UUID receiptId,
            UUID receiptItemId,
            UUID orderId,
            UUID orderItemId,
            BigDecimal declaredQty,
            BigDecimal approvedRemainingQty,
            BigDecimal unitPrice,
            BigDecimal declaredAmountOriginal,
            BigDecimal declaredAmountLocal,
            UUID ownerUserId,
            UUID ownerEmployeeId,
            UUID financeAssigneeUserId,
            UUID financeAssigneeEmployeeId,
            String status,
            long version) {
    }

    private record LockedReturnTask(
            UUID id,
            UUID exceptionId,
            UUID ownerUserId,
            UUID ownerEmployeeId,
            String status,
            long version) {
    }

    private record CapacityAtLine(ArrivalRow row, BigDecimal available) {
    }

    /** 一键入库目标（orderType + 收货单 id），供控制器分派到对应收货单审核链路。 */
    public record StockTarget(String orderType, UUID receiptId) {
    }

    /** 货品主档学习回写用到的当前值快照（code/series/stock_place）。 */
    private record GoodsMasterRow(String code, String series, String stockPlace) {
    }

    private record PostedAllowance(
            UUID id,
            UUID orderItemId,
            UUID expectationItemId,
            BigDecimal approvedExcessQty,
            long version) {
    }

    private enum ActionScope {
        NONE, OWNER, FINANCE
    }

    private record ExpectationHeader(
            UUID id,
            String orderType,
            UUID orderId,
            String billNo,
            UUID supplierId,
            String supplierName,
            UUID warehouseId,
            String warehouseName,
            LocalDate expectedDate,
            UUID ownerEmployeeId,
            String ownerEmployeeName,
            String status,
            BigDecimal orderedQty,
            BigDecimal acceptedQty,
            BigDecimal remainingQty) {
    }
}
