package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementArrivalBlockedException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.receipt.dto.ReceiptDetail;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterResult;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * 仓库到货登记一步完成：登记 + 送检审核同事务（「登记实际到货」保存即推进到品质待检，
 * 仓库不再被迫进入采购/委外收货单编辑页补币种等采购字段，也不再需要手动点「审核」）。
 *
 * <p>职责边界：
 * <ul>
 *   <li>币族权威回填——币种/汇率/结算方式不来自客户端，而是按明细 orderItemId 回查
 *       财务批准的来源订货单表头带出（多张订货单来源或快照不完整即 fail-closed）；
 *       价格仍由收货审核链路（ReceiptAmountAuthority）按订货明细权威重算。</li>
 *   <li>复用各收货单 Service 的 create + approve 完整链路（校验/IQC 隔离/订货回写/立应付/
 *       recordApproval），本服务不另写任何库存或应付逻辑；权限同样由两段服务自身的
 *       @PreAuthorize 收口（create + approve，仓库经 purchase_receipt:edit /
 *       subcontract_receipt:edit 蕴含获得）。</li>
 *   <li>实到超量时 approve 抛 {@link ProcurementArrivalBlockedException}
 *       （草稿 + PENDING_FINANCE 异常已提交），这里翻译为正常响应
 *       {@code EXCESS_QUARANTINED}，前端引导到「到货异常任务中心」等待财务定案。</li>
 * </ul>
 */
@Service
public class WarehouseArrivalRegistrationService {

    static final String OUTCOME_INSPECTED = "SUBMITTED_FOR_INSPECTION";
    static final String OUTCOME_QUARANTINED = "EXCESS_QUARANTINED";

    private static final String PURCHASE = "PURCHASE";
    private static final String SUBCONTRACT = "SUBCONTRACT";

    private final JdbcTemplate jdbc;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final PurchaseReceiptService purchaseReceiptService;
    private final SubcontractReceiptService subcontractReceiptService;

    public WarehouseArrivalRegistrationService(
            JdbcTemplate jdbc,
            TxSessionVars tx,
            SecurityContextCurrentUser currentUser,
            PurchaseReceiptService purchaseReceiptService,
            SubcontractReceiptService subcontractReceiptService) {
        this.jdbc = jdbc;
        this.tx = tx;
        this.currentUser = currentUser;
        this.purchaseReceiptService = purchaseReceiptService;
        this.subcontractReceiptService = subcontractReceiptService;
    }

    @Transactional(noRollbackFor = ProcurementArrivalBlockedException.class)
    public WarehouseArrivalRegisterResult register(WarehouseArrivalRegisterRequest request) {
        tx.bind();
        UUID makerId = currentUser.requireEmployeeId();
        String idempotencyKey = normalizeIdempotencyKey(request.idempotencyKey());
        String orderType = normalizeOrderType(request.orderType());
        String requestHash = requestHash(request);
        lockRegistrationCommand(makerId, idempotencyKey);
        ArrivalCommand replay = findRegistrationCommand(makerId, idempotencyKey);
        if (replay != null) {
            if (!Objects.equals(replay.requestHash(), requestHash)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "到货登记幂等键已用于不同内容，请刷新预计到货任务后重新登记");
            }
            return replayResult(replay);
        }
        UUID commandId = insertPendingCommand(
                makerId, idempotencyKey, requestHash, orderType);
        OrderHeader header = resolveOrderHeader(
                orderType,
                request.items().stream()
                        .map(WarehouseArrivalRegisterRequest.ArrivalLine::orderItemId).toList(),
                request.supplierId());
        UUID receiptId;
        String billNo;
        if (PURCHASE.equals(orderType)) {
            ReceiptDetail created =
                    purchaseReceiptService.create(purchaseRequest(request, header));
            receiptId = created.getId();
            billNo = created.getBillNo();
        } else {
            com.uten.imp.features.subcontract.receipt.dto.ReceiptDetail created =
                    subcontractReceiptService.create(subcontractRequest(request, header));
            receiptId = created.getId();
            billNo = created.getBillNo();
        }
        WarehouseArrivalRegisterResult result =
                approveAsArrival(orderType, receiptId, billNo);
        finalizeCommand(commandId, makerId, orderType, result);
        return result;
    }

    /**
     * 完成中断的到货登记（断点恢复）：老流程/网络中断留下的草稿收货单，由登记人在
     * 预计到货任务中心一键「继续送检」——不再进采购/委外收货单详情页手动点审核。
     *
     * <p>对历史草稿同时做**币族权威修复**：老登记链路建的草稿不带币种/汇率/结算方式
     * （审核必报「与财务批准订单不一致」），这里按来源订货单表头覆盖修正后再走
     * 同一审核链路；供应商一并按订货单对齐。仅草稿态可修正（未审核、无下游）。
     */
    @Transactional(noRollbackFor = ProcurementArrivalBlockedException.class)
    public WarehouseArrivalRegisterResult complete(UUID receiptId) {
        tx.bind();
        DraftReceipt draft = requireDraft(receiptId);
        OrderHeader header = resolveOrderHeader(
                draft.orderType(), draft.orderItemIds(), null);
        alignDraftHeader(draft, header);
        return approveAsArrival(draft.orderType(), receiptId, draft.billNo());
    }

    /** 统一的送检审核：正常转 IQC；实到超量翻译为 EXCESS_QUARANTINED（草稿+异常已提交）。 */
    private WarehouseArrivalRegisterResult approveAsArrival(
            String orderType, UUID receiptId, String billNo) {
        try {
            if (PURCHASE.equals(orderType)) {
                purchaseReceiptService.approve(receiptId);
            } else {
                subcontractReceiptService.approve(receiptId);
            }
        } catch (ProcurementArrivalBlockedException blocked) {
            UUID exceptionId = latestPendingExceptionId(receiptId);
            if (exceptionId == null) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "到货超量已被拦截，但缺少待财务异常记录；本次登记已回滚");
            }
            return new WarehouseArrivalRegisterResult(
                    OUTCOME_QUARANTINED, receiptId, billNo,
                    exceptionId);
        }
        return new WarehouseArrivalRegisterResult(
                OUTCOME_INSPECTED, receiptId, billNo, null);
    }

    /** 待审核草稿定位：先采购后委外；不存在或非草稿（含已删/已审/红冲）一律 NOT_FOUND。 */
    private DraftReceipt requireDraft(UUID receiptId) {
        for (String orderType : List.of(PURCHASE, SUBCONTRACT)) {
            String receiptTable = PURCHASE.equals(orderType)
                    ? "purchase_receipts" : "subcontract_receipts";
            String receiptItemTable = PURCHASE.equals(orderType)
                    ? "purchase_receipt_items" : "subcontract_receipt_items";
            List<String> billNos = jdbc.queryForList(
                    "SELECT bill_no FROM %s WHERE id = ? AND status = 0 AND is_deleted = FALSE"
                            .formatted(receiptTable),
                    String.class, receiptId);
            if (billNos.isEmpty()) continue;
            List<UUID> orderItemIds = jdbc.queryForList(
                    "SELECT order_item_id FROM %s WHERE receipt_id = ? AND order_item_id IS NOT NULL"
                            .formatted(receiptItemTable),
                    UUID.class, receiptId);
            if (orderItemIds.isEmpty()) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "该收货单明细未关联订货明细，无法继续送检；请在收货单模块处理");
            }
            return new DraftReceipt(receiptId, orderType, billNos.getFirst(), orderItemIds);
        }
        throw new ApiException(ErrorCode.NOT_FOUND, "收货单不存在或不是待审核草稿");
    }

    /** 币族权威修复（仅草稿态）：按来源订货单覆盖 供应商/币种/汇率/结算方式。 */
    private void alignDraftHeader(DraftReceipt draft, OrderHeader header) {
        String receiptTable = PURCHASE.equals(draft.orderType())
                ? "purchase_receipts" : "subcontract_receipts";
        int updated = jdbc.update("""
                UPDATE %s
                SET supplier_id = ?, currency_id = ?, exchange_rate = ?, settlement_method_id = ?
                WHERE id = ? AND status = 0 AND is_deleted = FALSE
                """.formatted(receiptTable),
                header.supplierId(), header.currencyId(), header.exchangeRate(),
                header.settlementMethodId(), draft.receiptId());
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "收货单状态已变化，请刷新后重试");
        }
    }

    private ReceiptSaveRequest purchaseRequest(
            WarehouseArrivalRegisterRequest request, OrderHeader header) {
        ReceiptSaveRequest req = new ReceiptSaveRequest();
        req.setBillDate(request.billDate());
        req.setSupplierId(header.supplierId());
        req.setWarehouseId(request.warehouseId());
        req.setCurrencyId(header.currencyId());
        req.setExchangeRate(header.exchangeRate());
        req.setSettlementMethodId(header.settlementMethodId());
        req.setPurchaserId(request.purchaserId());
        req.setReceiverId(request.receiverEmployeeId());
        req.setRemark(request.remark());
        req.setItems(purchaseLines(request));
        return req;
    }

    private List<ReceiptItemLine> purchaseLines(WarehouseArrivalRegisterRequest request) {
        List<ReceiptItemLine> lines = new ArrayList<>(request.items().size());
        int autoLine = 1;
        for (var line : request.items()) {
            ReceiptItemLine item = new ReceiptItemLine();
            item.setLineNo(autoLine++);
            item.setGoodsId(line.goodsId());
            item.setColorId(line.colorId());
            item.setUnitId(line.unitId());
            item.setUnitRate(line.unitRate());
            item.setQty(line.qty());
            item.setOrderItemId(line.orderItemId());
            item.setSourceDocNo(line.sourceDocNo());
            lines.add(item);
        }
        return lines;
    }

    private com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest subcontractRequest(
            WarehouseArrivalRegisterRequest request, OrderHeader header) {
        var req = new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        req.setBillDate(request.billDate());
        req.setSupplierId(header.supplierId());
        req.setWarehouseId(request.warehouseId());
        req.setCurrencyId(header.currencyId());
        req.setExchangeRate(header.exchangeRate());
        req.setSettlementMethodId(header.settlementMethodId());
        // 委外进仓单主档仅 sender_id 一个人员列，服务端按「收货人」语义解析。
        req.setSenderId(request.receiverEmployeeId());
        req.setRemark(request.remark());
        req.setItems(subcontractLines(request));
        return req;
    }

    private List<com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine> subcontractLines(
            WarehouseArrivalRegisterRequest request) {
        List<com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine> lines =
                new ArrayList<>(request.items().size());
        int autoLine = 1;
        for (var line : request.items()) {
            var item =
                    new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
            item.setLineNo(autoLine++);
            item.setGoodsId(line.goodsId());
            item.setColorId(line.colorId());
            item.setUnitId(line.unitId());
            item.setUnitRate(line.unitRate());
            item.setQty(line.qty());
            item.setOrderItemId(line.orderItemId());
            item.setSourceDocNo(line.sourceDocNo());
            lines.add(item);
        }
        return lines;
    }

    /**
     * 来源订货单表头快照：按明细 orderItemId 回查，多单来源 fail-closed。
     * expectedSupplierId 非空时校验与订货单一致（登记请求带供应商）；
     * complete 场景传 null（直接以订货单为权威覆盖草稿表头）。
     */
    private OrderHeader resolveOrderHeader(
            String orderType, List<UUID> orderItemIds, UUID expectedSupplierId) {
        String orderTable = PURCHASE.equals(orderType)
                ? "purchase_orders" : "subcontract_orders";
        String orderItemTable = PURCHASE.equals(orderType)
                ? "purchase_order_items" : "subcontract_order_items";
        String placeholders = String.join(", ",
                Collections.nCopies(orderItemIds.size(), "?"));
        List<OrderHeader> headers = jdbc.query("""
                SELECT DISTINCT order_doc.supplier_id, order_doc.currency_id,
                       order_doc.exchange_rate, order_doc.settlement_method_id
                FROM %s order_item
                JOIN %s order_doc ON order_doc.id = order_item.order_id
                WHERE order_item.id IN (%s)
                """.formatted(orderItemTable, orderTable, placeholders), (rs, rowNum) -> new OrderHeader(
                rs.getObject("supplier_id", UUID.class),
                rs.getObject("currency_id", UUID.class),
                rs.getBigDecimal("exchange_rate"),
                rs.getObject("settlement_method_id", UUID.class)),
                orderItemIds.toArray());
        if (headers.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "到货登记明细必须全部来自同一张财务批准的订货单");
        }
        OrderHeader header = headers.getFirst();
        if (expectedSupplierId != null
                && (header.supplierId() == null || !header.supplierId().equals(expectedSupplierId))) {
            throw new ApiException(ErrorCode.CONFLICT, "供应商与来源订货单不一致");
        }
        if (header.supplierId() == null || header.currencyId() == null
                || header.exchangeRate() == null || header.settlementMethodId() == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "来源订货单币种/汇率/结算方式不完整，禁止登记到货");
        }
        return header;
    }

    private UUID latestPendingExceptionId(UUID receiptId) {
        List<UUID> ids = jdbc.query("""
                SELECT id FROM procurement_arrival_exceptions
                WHERE receipt_id = ? AND status = 'PENDING_FINANCE'
                ORDER BY detected_at DESC, id
                LIMIT 1
                """, (rs, rowNum) -> rs.getObject("id", UUID.class), receiptId);
        return ids.isEmpty() ? null : ids.getFirst();
    }

    private void lockRegistrationCommand(UUID makerId, String idempotencyKey) {
        jdbc.queryForObject(
                "SELECT pg_advisory_xact_lock(hashtextextended(?, 0)) IS NULL",
                Boolean.class,
                "WAREHOUSE_ARRIVAL_REGISTER|" + makerId + "|" + idempotencyKey);
    }

    private ArrivalCommand findRegistrationCommand(
            UUID makerId, String idempotencyKey) {
        List<ArrivalCommand> rows = jdbc.query("""
                SELECT request_hash, status, outcome,
                       purchase_receipt_id, subcontract_receipt_id,
                       receipt_bill_no_snapshot, exception_id
                FROM warehouse_arrival_registration_commands
                WHERE maker_id = ? AND idempotency_key = ?
                """, (rs, rowNum) -> new ArrivalCommand(
                rs.getString("request_hash"),
                rs.getString("status"),
                rs.getString("outcome"),
                rs.getObject("purchase_receipt_id", UUID.class),
                rs.getObject("subcontract_receipt_id", UUID.class),
                rs.getString("receipt_bill_no_snapshot"),
                rs.getObject("exception_id", UUID.class)),
                makerId, idempotencyKey);
        if (rows.size() > 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "到货登记幂等键存在重复历史，请先完成数据核对");
        }
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private UUID insertPendingCommand(
            UUID makerId, String idempotencyKey,
            String requestHash, String orderType) {
        UUID commandId = UUID.randomUUID();
        int inserted = jdbc.update("""
                INSERT INTO warehouse_arrival_registration_commands(
                    id, maker_id, idempotency_key, request_hash, order_type)
                VALUES (?, ?, ?, ?, ?)
                """, commandId, makerId, idempotencyKey, requestHash, orderType);
        if (inserted != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "到货登记命令未能建立，请刷新后重试");
        }
        return commandId;
    }

    private void finalizeCommand(
            UUID commandId, UUID makerId, String orderType,
            WarehouseArrivalRegisterResult result) {
        boolean quarantined = OUTCOME_QUARANTINED.equals(result.outcome());
        if (quarantined && result.exceptionId() == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "到货隔离结果缺少异常标识，本次登记已回滚");
        }
        UUID purchaseReceiptId = PURCHASE.equals(orderType)
                ? result.receiptId() : null;
        UUID subcontractReceiptId = SUBCONTRACT.equals(orderType)
                ? result.receiptId() : null;
        int updated = jdbc.update("""
                UPDATE warehouse_arrival_registration_commands
                SET status = ?, outcome = ?,
                    purchase_receipt_id = ?, subcontract_receipt_id = ?,
                    receipt_bill_no_snapshot = ?, exception_id = ?,
                    completed_at = now()
                WHERE id = ? AND maker_id = ? AND status = 'PENDING'
                """,
                quarantined ? "QUARANTINED" : "COMPLETED",
                result.outcome(), purchaseReceiptId, subcontractReceiptId,
                result.receiptBillNo(), result.exceptionId(),
                commandId, makerId);
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "到货登记命令状态已变化，本次登记已回滚");
        }
    }

    private static WarehouseArrivalRegisterResult replayResult(ArrivalCommand command) {
        if ("PENDING".equals(command.status())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "同一到货登记请求仍在处理中，请稍后以原请求重试");
        }
        UUID receiptId = command.purchaseReceiptId() != null
                ? command.purchaseReceiptId() : command.subcontractReceiptId();
        if (receiptId == null || command.outcome() == null
                || command.receiptBillNo() == null
                || !("COMPLETED".equals(command.status())
                || "QUARANTINED".equals(command.status()))) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "到货登记幂等记录不完整，请先完成数据核对");
        }
        return new WarehouseArrivalRegisterResult(
                command.outcome(), receiptId,
                command.receiptBillNo(), command.exceptionId());
    }

    static String normalizeIdempotencyKey(String raw) {
        String value = raw == null ? null : raw.trim();
        if (value == null || value.length() < 8 || value.length() > 128
                || !value.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "到货登记幂等键格式不正确");
        }
        return value;
    }

    static String requestHash(WarehouseArrivalRegisterRequest request) {
        StringBuilder canonical = new StringBuilder();
        appendHash(canonical, normalizeOrderType(request.orderType()));
        appendHash(canonical, request.billDate());
        appendHash(canonical, request.supplierId());
        appendHash(canonical, request.warehouseId());
        appendHash(canonical, request.purchaserId());
        appendHash(canonical, request.receiverEmployeeId());
        appendHash(canonical, request.remark());
        List<WarehouseArrivalRegisterRequest.ArrivalLine> items =
                request.items() == null ? List.of() : request.items();
        appendHash(canonical, items.size());
        for (var item : items) {
            appendHash(canonical, item == null ? null : item.goodsId());
            appendHash(canonical, item == null ? null : decimalText(item.qty()));
            appendHash(canonical, item == null ? null : item.orderItemId());
            appendHash(canonical, item == null ? null : item.colorId());
            appendHash(canonical, item == null ? null : item.unitId());
            appendHash(canonical, item == null ? null : decimalText(item.unitRate()));
            appendHash(canonical, item == null ? null : item.sourceDocNo());
        }
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(canonical.toString().getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    private static void appendHash(StringBuilder target, Object value) {
        String text = value == null ? "" : value.toString();
        target.append(text.length()).append(':').append(text).append('|');
    }

    private static String decimalText(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros().toPlainString();
    }

    private static String normalizeOrderType(String orderType) {
        String normalized = orderType == null ? "" : orderType.strip().toUpperCase();
        return switch (normalized) {
            case PURCHASE, SUBCONTRACT -> normalized;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货类型无效");
        };
    }

    /** 来源订货单表头（审核 requireHeaderMatches 的权威口径）。 */
    private record OrderHeader(
            UUID supplierId, UUID currencyId,
            BigDecimal exchangeRate, UUID settlementMethodId) {
    }

    /** 待完成的草稿收货单定位：id + 类型 + 单号 + 关联的订货明细。 */
    private record DraftReceipt(
            UUID receiptId, String orderType, String billNo, List<UUID> orderItemIds) {
    }

    static record ArrivalCommand(
            String requestHash,
            String status,
            String outcome,
            UUID purchaseReceiptId,
            UUID subcontractReceiptId,
            String receiptBillNo,
            UUID exceptionId) {
    }
}
