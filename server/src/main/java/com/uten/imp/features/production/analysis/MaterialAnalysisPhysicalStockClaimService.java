package com.uten.imp.features.production.analysis;

import com.uten.imp.common.inventory.MainWarehouseStockBudget;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Turns explicitly adopted public physical stock into real, source-owned reservations. */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisPhysicalStockClaimService {
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final InventoryMutationLock inventoryLock;
    private final ObjectProvider<MaterialAnalysisService> snapshots;

    /** The caller supplies the new adoption ceiling, already net of existing private coverage. */
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean claim(UUID analysisId, Map<UUID, BigDecimal> maxByMaterial, String key) {
        if (maxByMaterial == null || maxByMaterial.isEmpty()) return false;
        tx.bind();
        if (analysisId == null || key == null || key.isBlank()) throw conflict("公共现货采用缺少原始命令身份");
        final var view = snapshots.getObject().detailInternal(analysisId, false);
        final var byId = new HashMap<UUID, MaterialAnalysisContracts.MaterialView>();
        view.flatMaterials().forEach(row -> byId.put(row.materialLineId(), row));
        final var ordered = maxByMaterial.entrySet().stream().sorted(Map.Entry.comparingByKey()).toList();
        final var fingerprint = new ArrayList<String>();
        fingerprint.add(analysisId.toString());
        for (final var entry : ordered) {
            final var material = byId.get(entry.getKey());
            if (material == null || entry.getValue() == null || entry.getValue().signum() < 0
                    || entry.getValue().stripTrailingZeros().scale() > 4) {
                throw conflict("公共现货采用的物料身份或库存精度无法核对");
            }
            fingerprint.add(entry.getKey() + ":" + entry.getValue().stripTrailingZeros().toPlainString());
        }
        inventoryLock.lockAll(ordered.stream().map(entry -> byId.get(entry.getKey()))
                .map(row -> new InventoryKey(row.goodsId(), row.colorId())).toList());
        final String hash = CanonicalFingerprint.sha256(fingerprint);
        final UUID commandId = UUID.randomUUID();
        final int inserted = em.createNativeQuery("""
                INSERT INTO preplan_physical_stock_claim_commands(id,analysis_id,idempotency_key,request_hash,created_by)
                VALUES(:id,:analysis,:key,:hash,:actor) ON CONFLICT(idempotency_key) DO NOTHING
                """).setParameter("id", commandId).setParameter("analysis", analysisId)
                .setParameter("key", key).setParameter("hash", hash)
                .setParameter("actor", currentUser.requireId()).executeUpdate();
        final var existing = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,analysis_id,request_hash FROM preplan_physical_stock_claim_commands
                WHERE idempotency_key=:key FOR UPDATE
                """).setParameter("key", key)).getFirst();
        if (!analysisId.equals(existing[1]) || !hash.equals(existing[2])) throw conflict("原公共现货采用命令内容发生变化，不能重复下单");
        if (inserted == 0) return false;

        // Re-read after acquiring the shared inventory mutex. A competing analysis
        // may have adopted stock while this transaction waited for its turn.
        final var lockedView = snapshots.getObject().detailInternal(analysisId, false);
        byId.clear();
        lockedView.flatMaterials().forEach(row -> byId.put(row.materialLineId(), row));
        boolean changed = false;
        for (final var entry : ordered) {
            final var material = byId.get(entry.getKey());
            if (material == null) throw conflict("原公共现货采用来源已经变化");
            if ("ROOT_SUPPLY".equals(material.nodeRole())) continue;
            final var aggregate = material.aggregatePreparation();
            final boolean effectiveNeed = material.requiredQty().signum() > 0
                    || aggregate != null && aggregate.actionable() && aggregate.requiredQty().signum() > 0;
            if (!effectiveNeed) continue;
            BigDecimal remaining = entry.getValue().min(nonnegative(material.preparationUncoveredBeforeSharedQty()));
            if (remaining.signum() <= 0) continue;
            final var leaves = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT stock.warehouse_id,CAST(GREATEST(CAST(stock.qty AS numeric)
                      -COALESCE((SELECT SUM(r.qty-r.consumed_qty-r.released_qty) FROM stock_reservations r
                        WHERE r.goods_id=:goods AND r.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                          AND r.warehouse_id=stock.warehouse_id
                          AND r.status=0 AND NOT r.is_deleted),CAST(0 AS numeric)),CAST(0 AS numeric)) AS numeric),
                      CAST(GREATEST(COALESCE(CAST(goods.min_qty AS numeric),CAST(0 AS numeric)),CAST(0 AS numeric)) AS numeric),
                      CAST(COALESCE((SELECT SUM(r.qty-r.consumed_qty-r.released_qty) FROM stock_reservations r
                        WHERE r.goods_id=:goods AND r.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                          AND r.warehouse_id IS NULL AND r.status=0 AND NOT r.is_deleted),CAST(0 AS numeric)) AS numeric)
                    FROM v_stock_operable_balances stock JOIN goods ON goods.id=stock.goods_id
                    JOIN production_material_analyses analysis ON analysis.id=:analysis
                    WHERE stock.goods_id=:goods AND stock.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                      AND fn_warehouse_same_main(stock.warehouse_id,analysis.warehouse_id)
                      AND fn_warehouse_is_good_stock_leaf(stock.warehouse_id)
                      AND NOT analysis.is_deleted AND analysis.status IN('ACTIVE','PARTIALLY_PLANNED')
                    ORDER BY stock.warehouse_id
                    """).setParameter("goods", material.goodsId()).setParameter("color", material.colorId())
                    .setParameter("analysis", analysisId));
            final var usable = MainWarehouseStockBudget.distribute(leaves.stream().map(leaf ->
                    new MainWarehouseStockBudget.Leaf<>((UUID) leaf[0], (BigDecimal) leaf[1],
                            BigDecimal.ZERO, BigDecimal.ZERO)).toList(), leaves.isEmpty() ? BigDecimal.ZERO
                    : ((BigDecimal) leaves.getFirst()[2]).add((BigDecimal) leaves.getFirst()[3]));
            for (final var leaf : leaves) {
                final BigDecimal take = remaining.min(usable.get((UUID) leaf[0]));
                if (take.signum() <= 0) continue;
                final UUID reservation = UUID.randomUUID();
                final String reservationKey = "PREPLAN-STOCK:" + CanonicalFingerprint.sha256(List.of(
                        commandId.toString(), entry.getKey().toString(), leaf[0].toString()));
                em.createNativeQuery("""
                        INSERT INTO stock_reservations(id,owner_type,owner_id,purpose,goods_id,color_id,warehouse_id,
                          qty,consumed_qty,released_qty,status,source,source_doc_type,source_doc_id,supply_type,supply_id,
                          idempotency_key,created_by,updated_by)
                        VALUES(:id,'PREPLAN_ANALYSIS',:analysis,'PREPLAN_MATERIAL',:goods,:color,:warehouse,
                          :qty,0,0,0,3,'PREPLAN_STOCK_BALANCE',:material,'STOCK_BALANCE',:material,:key,:actor,:actor)
                        """).setParameter("id", reservation).setParameter("analysis", analysisId)
                        .setParameter("goods", material.goodsId()).setParameter("color", material.colorId())
                        .setParameter("warehouse", leaf[0]).setParameter("qty", take)
                        .setParameter("material", entry.getKey()).setParameter("key", reservationKey)
                        .setParameter("actor", currentUser.requireId()).executeUpdate();
                em.createNativeQuery("""
                        INSERT INTO preplan_physical_stock_claim_allocations(command_id,stock_reservation_id,material_id,qty)
                        VALUES(:command,:reservation,:material,:qty)
                        """).setParameter("command", commandId).setParameter("reservation", reservation)
                        .setParameter("material", entry.getKey()).setParameter("qty", take).executeUpdate();
                changed = true;
                remaining = remaining.subtract(take);
                if (remaining.signum() == 0) break;
            }
        }
        return changed;
    }

    @Transactional(readOnly = true)
    public Map<UUID, BigDecimal> ownedByMaterial(UUID analysisId) {
        return quantities(analysisId, false);
    }

    @Transactional(readOnly = true)
    public Map<UUID, BigDecimal> adoptedByMaterial(UUID analysisId) {
        return quantities(analysisId, true);
    }

    private Map<UUID, BigDecimal> quantities(UUID analysisId, boolean includeFormalized) {
        final var result = new HashMap<UUID, BigDecimal>();
        for (final var row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reservation.supply_id,CAST(SUM(GREATEST(CASE WHEN reservation.status=0 AND NOT reservation.is_deleted
                  THEN reservation.qty-reservation.consumed_qty-reservation.released_qty ELSE 0 END,0)
                  +CASE WHEN :adopted THEN COALESCE((SELECT SUM(handoff.qty)
                    FROM preplan_physical_stock_formalizations handoff
                    WHERE handoff.source_reservation_id=reservation.id AND handoff.restored_at IS NULL),0) ELSE 0 END) AS numeric)
                FROM stock_reservations reservation JOIN production_material_analyses analysis ON analysis.id=reservation.owner_id
                WHERE reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.owner_id=:analysis
                  AND reservation.source_doc_type='PREPLAN_STOCK_BALANCE' AND reservation.supply_type='STOCK_BALANCE'
                  AND reservation.source_doc_id=reservation.supply_id
                  AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED'
                GROUP BY reservation.supply_id
                """).setParameter("analysis", analysisId).setParameter("adopted", includeFormalized))) {
            result.put((UUID) row[0], (BigDecimal) row[1]);
        }
        return Map.copyOf(result);
    }

    private static BigDecimal nonnegative(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value.max(BigDecimal.ZERO);
    }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
