package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryCostSourceEvidencePort.Evidence;
import com.uten.imp.application.port.InventoryValuationPort.PoolKey;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/** Reads the approved supplier charge of one immutable receipt partition. */
@Service
public class ProcurementCostSourceEvidenceService implements InventoryApprovedCostEvidenceReader {
    private final NamedParameterJdbcTemplate db;

    public ProcurementCostSourceEvidenceService(NamedParameterJdbcTemplate db) {
        this.db = db;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public Optional<Evidence> approved(UUID evidenceId, long version) {
        if (evidenceId == null || version != 1) return Optional.empty();
        List<Map<String, Object>> rows = db.queryForList("""
                WITH part AS MATERIALIZED (
                    SELECT * FROM procurement_receipt_consideration_parts
                    WHERE id=:id AND fn_procurement_consideration_active('CONSIDERATION',id)
                ), receipt_source AS (
                    SELECT p.id,p.receipt_type,p.receipt_id,p.receipt_item_id,p.billing_mode,
                           p.base_qty,p.payable_local,p.funding_slice_id,
                           r.warehouse_id,i.goods_id,i.color_id
                    FROM part p
                    JOIN purchase_receipts r ON p.receipt_type='PURCHASE' AND r.id=p.receipt_id
                        AND r.status=1 AND NOT r.is_deleted
                    JOIN purchase_receipt_items i ON i.id=p.receipt_item_id AND i.receipt_id=r.id
                        AND NOT i.is_deleted
                    UNION ALL
                    SELECT p.id,p.receipt_type,p.receipt_id,p.receipt_item_id,p.billing_mode,
                           p.base_qty,p.payable_local,p.funding_slice_id,
                           r.warehouse_id,i.goods_id,i.color_id
                    FROM part p
                    JOIN subcontract_receipts r ON p.receipt_type='SUBCONTRACT' AND r.id=p.receipt_id
                        AND r.status=1 AND NOT r.is_deleted
                    JOIN subcontract_receipt_items i ON i.id=p.receipt_item_id AND i.receipt_id=r.id
                        AND NOT i.is_deleted
                )
                SELECT source.*,ap.id AS ap_id
                FROM receipt_source source
                LEFT JOIN ar_ap_ledger ap ON ap.source_doc_type=source.receipt_type||'_RECEIPT'
                    AND ap.source_doc_id=source.receipt_id AND ap.direction='AP'
                    AND ap.status=1 AND NOT ap.is_deleted
                """, Map.of("id", evidenceId));
        if (rows.isEmpty()) return Optional.empty();
        if (rows.size() != 1) throw conflict("收货费用对应多笔有效应付，请先核对来源");
        return evidence(rows.getFirst());
    }

    static Optional<Evidence> evidence(Map<String, Object> row) {
        UUID id = (UUID) row.get("id");
        UUID receiptId = (UUID) row.get("receipt_id");
        UUID receiptItemId = (UUID) row.get("receipt_item_id");
        UUID warehouseId = (UUID) row.get("warehouse_id");
        UUID goodsId = (UUID) row.get("goods_id");
        String mode = (String) row.get("billing_mode");
        BigDecimal qty = (BigDecimal) row.get("base_qty");
        BigDecimal charge = (BigDecimal) row.get("payable_local");
        if (id == null || receiptId == null || receiptItemId == null
                || warehouseId == null || goodsId == null || qty == null || qty.signum() <= 0
                || charge == null || charge.signum() < 0) return Optional.empty();
        boolean carried = "NO_CHARGE".equals(mode);
        if (!carried && !"STANDARD".equals(mode) && !"CREDIT_REPURCHASE".equals(mode)) {
            return Optional.empty();
        }
        if (carried && (charge.signum() != 0 || row.get("funding_slice_id") == null)) {
            return Optional.empty();
        }
        if (!carried && charge.signum() > 0 && row.get("ap_id") == null) {
            return Optional.empty();
        }
        BigDecimal exactCharge = FinancialExactAmount.book(charge, "收货已确认费用");
        String basis = String.join("|", "PROCUREMENT_RECEIPT_COST_V1", id.toString(),
                String.valueOf(row.get("receipt_type")), receiptId.toString(), receiptItemId.toString(),
                mode, warehouseId.toString(), goodsId.toString(), String.valueOf(row.get("color_id")),
                qty.stripTrailingZeros().toPlainString(), exactCharge.toPlainString(),
                String.valueOf(row.get("funding_slice_id")), String.valueOf(row.get("ap_id")));
        return Optional.of(new Evidence(id, 1,
                new PoolKey(warehouseId, goodsId, (UUID) row.get("color_id")),
                qty, carried ? qty : BigDecimal.ZERO, exactCharge, true,
                "PROCUREMENT_RECEIPT_PART", id, 1, sha256(basis)));
    }

    private static String sha256(String text) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
