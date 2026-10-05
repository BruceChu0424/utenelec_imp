package com.uten.imp.common.concurrency;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * ADR-098 × ADR-090(2026-10-05)：委外回厂走「先入库后质检」时，品质合格本该按上架位置自动转为可用库存；
 * 这张收货单还有待委外判定的回厂短交时，转正先扣住(货已在库位上，只是还不是可用库存)。
 * 这里只读出「已上架、品质已放行、一件都还没转正」的放行事件——判定 / 到齐的同一事务据此
 * 先把这些收货单并进首次预锁，再逐张补做自动转正。
 *
 * <p>上架仓失效退回仓库确认队列的放行事件也满足同一条件；补做时仍走同一条自动转正路径，
 * 上架仓仍不可用就再退回原队列(投递幂等)。已部分入库的放行事件不在这里(只有仓库手工确认才会部分入库)。
 */
public final class SubcontractHeldPreStock {

    private SubcontractHeldPreStock() {
    }

    /** 一条待转正的已上架放行事件: 收货单、PASS 事件、待检明细、上架仓与库位。 */
    public record Release(UUID receiptId, UUID passEventId, UUID inspectionItemId, UUID warehouseId, String place) {
    }

    private static final String SELECT = """
            SELECT inspection.receipt_id, event.id, inspection.id,
                   inspection.pre_stocked_warehouse_id, inspection.pre_stocked_place
            FROM procurement_inspection_items inspection
            JOIN procurement_inspection_events event
              ON event.inspection_item_id = inspection.id
             AND event.action = 'PASS'
             AND event.requires_warehouse_stock_in = TRUE
            WHERE inspection.receipt_type = 'SUBCONTRACT'
              AND inspection.status <> 'REVERSED'
              AND inspection.pre_stocked_warehouse_id IS NOT NULL
              AND NULLIF(BTRIM(inspection.pre_stocked_place), '') IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM procurement_iqc_stock_in_batch_items stocked
                  WHERE stocked.pass_event_id = event.id)
              AND %s
            ORDER BY inspection.receipt_id, event.id
            """;

    /** 这些委外订货明细(有效收货单上)的待转正已上架放行事件，按收货单、事件排序。 */
    public static List<Release> ofOrderItems(EntityManager em, Collection<UUID> orderItemIds) {
        List<UUID> ids = orderItemIds == null ? List.of() : orderItemIds.stream().filter(Objects::nonNull)
                .distinct().sorted(Comparator.comparing(UUID::toString)).toList();
        if (ids.isEmpty()) return List.of();
        return read(em.createNativeQuery(SELECT.formatted("""
                inspection.receipt_id IN (
                      SELECT receipt_item.receipt_id
                      FROM subcontract_receipt_items receipt_item
                      JOIN subcontract_receipts receipt ON receipt.id = receipt_item.receipt_id
                       AND receipt.status = 1 AND NOT receipt.is_deleted
                      WHERE receipt_item.order_item_id IN (:heldOrderItemIds)
                        AND NOT receipt_item.is_deleted)""")).setParameter("heldOrderItemIds", ids));
    }

    /** 一张委外收货单的待转正已上架放行事件。 */
    public static List<Release> ofReceipt(EntityManager em, UUID receiptId) {
        if (receiptId == null) return List.of();
        return read(em.createNativeQuery(SELECT.formatted("inspection.receipt_id = :heldReceiptId"))
                .setParameter("heldReceiptId", receiptId));
    }

    private static List<Release> read(jakarta.persistence.Query query) {
        List<Release> result = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            result.add(new Release((UUID) row[0], (UUID) row[1], (UUID) row[2], (UUID) row[3],
                    row[4] == null ? null : row[4].toString()));
        }
        return List.copyOf(result);
    }
}
