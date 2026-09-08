package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryCostSourceEvidencePort.Evidence;
import com.uten.imp.application.port.InventoryValuationPort.PoolKey;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import static com.uten.imp.features.stock.valuation.ValueMath.conflict;

/** A proven old shipment establishes quantity and provenance, never an invented historical cost. */
@Service
public class SalesReturnCostSourceEvidenceService implements InventoryApprovedCostEvidenceReader {
    private final NamedParameterJdbcTemplate db;

    public SalesReturnCostSourceEvidenceService(NamedParameterJdbcTemplate db) {
        this.db = db;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public Optional<Evidence> approved(UUID evidenceId, long version) {
        if (evidenceId == null || version != 1) return Optional.empty();
        var rows = db.queryForList("""
                SELECT movement.id,movement.qty,movement.warehouse_id,movement.goods_id,movement.color_id,
                       movement.source_doc_id,movement.source_item_id
                FROM stock_movements movement
                JOIN sales_shipment_items item ON item.id=movement.source_item_id
                    AND item.shipment_id=movement.source_doc_id AND NOT item.is_deleted
                    AND item.goods_id=movement.goods_id AND item.color_id IS NOT DISTINCT FROM movement.color_id
                JOIN sales_shipments shipment ON shipment.id=item.shipment_id
                    AND shipment.status=1 AND shipment.warehouse_work_status='SHIPPED' AND NOT shipment.is_deleted
                    AND shipment.warehouse_id=movement.warehouse_id
                WHERE movement.id=:id AND movement.source_doc_type='SALES_SHIPMENT'
                  AND movement.direction=-1 AND movement.movement_type IN (3,20)
                  AND movement.qty>0
                  AND NOT EXISTS(SELECT 1 FROM stock_value_events value_event
                      WHERE value_event.movement_id=movement.id)
                """, Map.of("id", evidenceId));
        if (rows.isEmpty()) return Optional.empty();
        if (rows.size() != 1) throw conflict("历史发货成本来源不唯一，请先核对原出库流水");
        Map<String, Object> row = rows.getFirst();
        BigDecimal qty = (BigDecimal) row.get("qty");
        String basis = String.join("|", "LEGACY_SALES_COST_UNVERIFIED", evidenceId.toString(),
                row.get("source_doc_id").toString(), row.get("source_item_id").toString(),
                row.get("warehouse_id").toString(), row.get("goods_id").toString(),
                String.valueOf(row.get("color_id")), qty.stripTrailingZeros().toPlainString());
        return Optional.of(new Evidence(evidenceId, 1,
                new PoolKey((UUID) row.get("warehouse_id"), (UUID) row.get("goods_id"), (UUID) row.get("color_id")),
                qty, BigDecimal.ZERO, null, false, "LEGACY_SALES_MOVEMENT", evidenceId, 1, sha256(basis)));
    }

    private static String sha256(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }
}
