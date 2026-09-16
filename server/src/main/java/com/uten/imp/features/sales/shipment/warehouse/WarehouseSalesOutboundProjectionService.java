package com.uten.imp.features.sales.shipment.warehouse;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.shipment.SalesShipment;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemDto;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Maps the authoritative sales shipment state machine to a warehouse-only read model.
 *
 * <p>V582 起可发量口径与 {@code assertWarehousePickCapacity} 完全对齐：只减安全库存与
 * 其它订单硬预留。一步式没有"已开拣但未出账"的在途量，原来三处
 * {@code warehouse_work_status IN('PICKING','PICKED')} 的减项随中间态一起删除；
 * 两侧口径必须同批修改，否则会出现"预览可发 / 确认报库存不足"的用户可见不一致。</p>
 */
@Service
public class WarehouseSalesOutboundProjectionService {

    private final SalesShipmentService shipments;
    private final EntityManager entityManager;

    public WarehouseSalesOutboundProjectionService(
            SalesShipmentService shipments,
            EntityManager entityManager) {
        this.shipments = shipments;
        this.entityManager = entityManager;
    }

    @Transactional(readOnly = true)
    public PageResponse<WarehouseSalesOutboundListItem> list(
            String keyword,
            String warehouseWorkStatus,
            LocalDate dateFrom,
            LocalDate dateTo,
            int page,
            int size) {
        PageResponse<ShipmentListItem> source = shipments.list(
                new ShipmentQueryFilter(
                        keyword,
                        null,
                        null,
                        (short) 0,
                        null,
                        (short) 1,
                        normalize(warehouseWorkStatus),
                        dateFrom,
                        dateTo),
                page,
                size,
                null,
                null);
        NameDirectory names = new NameDirectory(entityManager);
        List<WarehouseSalesOutboundListItem> items = source.getItems().stream()
                .map(item -> toListItem(item, names))
                .toList();
        return new PageResponse<>(
                items,
                source.getPage(),
                source.getSize(),
                source.getTotal(),
                source.getTotalPages());
    }

    @Transactional(readOnly = true)
    public WarehouseSalesOutboundDetail detail(UUID id) {
        return toDetail(requireWarehouseVisible(id));
    }

    /** 待出库任务计数（出库任务中心/工作台角标），与列表同一读范围与仓库口径。 */
    @Transactional(readOnly = true)
    public long pendingCount() {
        return shipments.countPendingWarehouseWork();
    }

    @Transactional
    public WarehouseSalesOutboundDetail transition(
            UUID id,
            WarehouseWorkTransitionRequest request) {
        requireWarehouseVisible(id);
        return toDetail(shipments.transitionWarehouseWork(id, request));
    }

    private ShipmentDetail requireWarehouseVisible(UUID id) {
        ShipmentDetail source = shipments.detail(id);
        if (source.getFinanceAudit() == null
                || source.getFinanceAudit() != 1
                || source.isRejected()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "仓库销售出库任务不存在");
        }
        return source;
    }

    private WarehouseSalesOutboundListItem toListItem(
            ShipmentListItem item,
            NameDirectory names) {
        return new WarehouseSalesOutboundListItem(
                item.getId(),
                item.getBillNo(),
                item.getBillDate(),
                item.getClientId(),
                names.client(item.getClientId()),
                item.getWarehouseId(),
                names.warehouse(item.getWarehouseId()),
                item.getWarehouseWorkStatus(),
                item.isCanManageWarehouseWork()
                        ? SalesShipmentService.allowedWarehouseTransitionTargets(
                                item.getWarehouseWorkStatus())
                        : List.of());
    }

    private WarehouseSalesOutboundDetail toDetail(ShipmentDetail source) {
        NameDirectory names = new NameDirectory(entityManager);
        List<?> modes=entityManager.createNativeQuery("SELECT warehouse_chosen_at_pick FROM sales_shipments WHERE id=:id")
                .setParameter("id",source.getId()).getResultList();
        boolean chosenAtPick=!modes.isEmpty() && Boolean.TRUE.equals(modes.getFirst());
        Map<UUID,String> stockPlaces=new HashMap<>();
        for(Object[] row:com.uten.imp.common.util.NativeQueryResults.objectArrayRows(entityManager.createNativeQuery("""
                SELECT entry.key::uuid,entry.value FROM sales_shipment_warehouse_events event
                CROSS JOIN LATERAL jsonb_each_text(event.line_stock_places) entry
                WHERE event.id=(SELECT latest.id FROM sales_shipment_warehouse_events latest
                    WHERE latest.shipment_id=:id AND latest.line_stock_places<>'{}'::jsonb
                    ORDER BY latest.occurred_at DESC,latest.id DESC LIMIT 1)
                """).setParameter("id",source.getId())))stockPlaces.put((UUID)row[0],(String)row[1]);
        List<String> allowedTargets = source.isCanManageWarehouseWork()
                ? SalesShipmentService.allowedWarehouseTransitionTargets(
                        source.getWarehouseWorkStatus())
                : List.of();
        List<WarehouseSalesOutboundLine> lines = source.getItems().stream()
                .map(item -> toLine(item, names,stockPlaces.get(item.getId())))
                .toList();
        return new WarehouseSalesOutboundDetail(
                source.getId(),
                source.getBillNo(),
                source.getBillDate(),
                source.getClientId(),
                names.client(source.getClientId()),
                source.getWarehouseId(),
                names.warehouse(source.getWarehouseId()),
                source.getShipAddr(),
                source.getLinkPhone(),
                source.getLogisticsNo(),
                source.getParcelCount(),
                source.getWarehouseWorkStatus(),
                source.getWarehouseWorkUpdatedAt(),
                source.getPickingStartedAt(),
                source.getPickedAt(),
                source.getHandedOverAt(),
                source.getWarehouseExceptionReason(),
                allowedTargets,
                lines,
                chosenAtPick && allowedTargets.contains(SalesShipment.WORK_SHIPPED),
                allowedTargets.contains(SalesShipment.WORK_SHIPPED)?warehouseOptions(source,chosenAtPick):List.of());
    }

    private WarehouseSalesOutboundLine toLine(
            ShipmentItemDto source,
            NameDirectory names,String actualStockPlace) {
        GoodsIdentity goods = names.goods(source.getGoodsId());
        return new WarehouseSalesOutboundLine(
                source.getId(),
                source.getLineNo(),
                source.getGoodsId(),
                firstNonBlank(source.getGoodsCodeSnapshot(), goods.code()),
                firstNonBlank(source.getGoodsNameSnapshot(), goods.name()),
                goods.stockPlaceHint(),
                source.getColorId(),
                names.color(source.getColorId()),
                source.getUnitId(),
                names.unit(source.getUnitId()),
                source.getQty(),
                source.getWeight(),
                source.getParcelQty(),
                source.getCartonCount(),
                source.getClientNo(),
                source.getClientModel(),
                source.getSourceDocNo(),actualStockPlace);
    }

    private List<WarehouseSalesOutboundWarehouseOption> warehouseOptions(ShipmentDetail source,boolean chosenAtPick) {
        // Sales detail intentionally hides order lineage from warehouse-only
        // actors. Inventory eligibility must still use the persisted source;
        // only quantities, never the hidden order identities, are returned.
        List<UUID> ownIds=com.uten.imp.common.util.NativeQueryResults.typedRows(entityManager.createNativeQuery("""
                SELECT DISTINCT order_item_id FROM sales_shipment_items
                WHERE shipment_id=:id AND NOT is_deleted AND order_item_id IS NOT NULL ORDER BY order_item_id
                """).setParameter("id",source.getId()),UUID.class);
        if(ownIds.isEmpty())ownIds=List.of(new UUID(0,0));
        List<Object[]> rows=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(entityManager.createNativeQuery("""
                WITH RECURSIVE active_wh AS (
                    SELECT id,name FROM warehouses WHERE parent_id IS NULL AND NOT is_deleted AND status='使用'
                    UNION ALL SELECT child.id,child.name FROM warehouses child JOIN active_wh parent ON parent.id=child.parent_id
                        WHERE NOT child.is_deleted AND child.status='使用'
                )
                SELECT warehouse.id,warehouse.name,item.id,item.order_item_id,item.goods_id,item.color_id,
                       COALESCE(item.unit_rate,1)::numeric,item.qty::numeric,
                       LEAST(GREATEST(COALESCE(balance.qty,0)-GREATEST(COALESCE(goods.min_qty::numeric,0),0)-COALESCE(other_reserved.qty,0),0),global_budget.qty)::numeric,
                       GREATEST(COALESCE(own.qty,0),0)::numeric
                FROM active_wh warehouse JOIN warehouses physical ON physical.id=warehouse.id
                JOIN sales_shipment_items item ON item.shipment_id=:shipment AND NOT item.is_deleted
                JOIN goods ON goods.id=item.goods_id
                LEFT JOIN stock_balances balance ON balance.warehouse_id=warehouse.id AND balance.goods_id=item.goods_id
                    AND balance.color_id IS NOT DISTINCT FROM item.color_id
                LEFT JOIN LATERAL (
                    SELECT sum(reservation.qty-reservation.consumed_qty-reservation.released_qty) qty FROM stock_reservations reservation
                    WHERE reservation.warehouse_id=warehouse.id AND reservation.goods_id=item.goods_id
                      AND reservation.color_id IS NOT DISTINCT FROM item.color_id AND NOT reservation.is_deleted AND reservation.status=0
                      AND (reservation.order_item_id IS NULL OR reservation.order_item_id NOT IN (:ownIds))
                ) other_reserved ON TRUE
                LEFT JOIN LATERAL (
                    SELECT sum(reservation.qty-reservation.consumed_qty-reservation.released_qty) qty FROM stock_reservations reservation
                    WHERE (reservation.warehouse_id IS NULL OR reservation.warehouse_id=warehouse.id)
                      AND reservation.order_item_id=item.order_item_id AND reservation.goods_id=item.goods_id
                      AND reservation.color_id IS NOT DISTINCT FROM item.color_id AND NOT reservation.is_deleted AND reservation.status=0
                ) own ON TRUE
                LEFT JOIN LATERAL (
                    SELECT GREATEST(COALESCE((SELECT sum(GREATEST(global_stock.qty-GREATEST(COALESCE(goods.min_qty::numeric,0),0),0))
                        FROM stock_balances global_stock WHERE global_stock.goods_id=item.goods_id AND global_stock.color_id IS NOT DISTINCT FROM item.color_id),0)
                      -COALESCE((SELECT sum(reservation.qty-reservation.consumed_qty-reservation.released_qty) FROM stock_reservations reservation
                        WHERE reservation.goods_id=item.goods_id AND reservation.color_id IS NOT DISTINCT FROM item.color_id
                          AND reservation.status=0 AND NOT reservation.is_deleted
                          AND (reservation.order_item_id IS NULL OR reservation.order_item_id NOT IN (:ownIds))),0),0)::numeric qty
                ) global_budget ON TRUE
                WHERE physical.is_accountable AND NOT EXISTS(SELECT 1 FROM warehouses child WHERE child.parent_id=warehouse.id AND NOT child.is_deleted)
                  AND (:choose OR warehouse.id=CAST(:warehouse AS uuid))
                  AND EXISTS(SELECT 1 FROM stock_balances present WHERE present.warehouse_id=warehouse.id AND present.qty>0
                    AND present.goods_id IN(SELECT goods_id FROM sales_shipment_items WHERE shipment_id=:shipment AND NOT is_deleted))
                ORDER BY warehouse.name,warehouse.id,item.line_no,item.id
                """).setParameter("shipment",source.getId()).setParameter("ownIds",ownIds)
                .setParameter("choose",chosenAtPick).setParameter("warehouse",source.getWarehouseId()));
        Map<UUID,List<WarehouseSalesOutboundWarehouseOption.Line>> lines=new LinkedHashMap<>();
        Map<UUID,String> names=new HashMap<>();
        Map<String,BigDecimal> physicalRemaining=new HashMap<>(),orderRemaining=new HashMap<>();
        for(Object[] row:rows) {
            UUID warehouse=(UUID)row[0],orderItem=(UUID)row[3];
            String physicalKey=warehouse+"|"+row[4]+"|"+row[5],orderKey=warehouse+"|"+orderItem;
            BigDecimal rate=(BigDecimal)row[6],required=(BigDecimal)row[7];
            BigDecimal available=physicalRemaining.computeIfAbsent(physicalKey,key->(BigDecimal)row[8]);
            if(orderItem!=null)available=available.min(orderRemaining.computeIfAbsent(orderKey,key->(BigDecimal)row[9]));
            BigDecimal taken=required.multiply(rate).min(available);
            physicalRemaining.computeIfPresent(physicalKey,(key,remaining)->remaining.subtract(taken));
            if(orderItem!=null)orderRemaining.computeIfPresent(orderKey,(key,remaining)->remaining.subtract(taken));
            lines.computeIfAbsent(warehouse,key->new ArrayList<>()).add(new WarehouseSalesOutboundWarehouseOption.Line(
                    (UUID)row[2],available.divide(rate,4,RoundingMode.DOWN),required));
            names.put(warehouse,(String)row[1]);
        }
        return lines.entrySet().stream().map(entry->new WarehouseSalesOutboundWarehouseOption(entry.getKey(),names.get(entry.getKey()),
                entry.getValue().stream().allMatch(line->line.availableQty().compareTo(line.requiredQty())>=0),List.copyOf(entry.getValue()))).toList();
    }

    /**
     * 作业状态筛选白名单。底层 list 的谓词是裸等值比较：不拦住已删除的
     * PICKING/PICKED/EXCEPTION，旧客户端的三个分段会静默返回空列表，
     * 用户会以为"单子丢了"。这里显式 fail-closed 报错，让灰度期的旧页面看到真实原因。
     */
    private static String normalize(String value) {
        if (value == null || value.isBlank()) return null;
        String normalized = value.trim().toUpperCase(java.util.Locale.ROOT);
        if (!ALLOWED_WORK_STATUS_FILTERS.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "仓库作业状态已简化为待出库与已出库，请刷新页面后重新筛选：" + normalized);
        }
        return normalized;
    }

    private static final java.util.Set<String> ALLOWED_WORK_STATUS_FILTERS = java.util.Set.of(
            SalesShipment.WORK_LEGACY_PENDING,
            SalesShipment.WORK_PENDING_PICK,
            SalesShipment.WORK_SHIPPED,
            SalesShipment.WORK_CANCELLED,
            SalesShipment.WORK_REVERSED);

    private static String firstNonBlank(String preferred, String fallback) {
        return preferred == null || preferred.isBlank() ? fallback : preferred;
    }

    private static final class NameDirectory {
        private final EntityManager entityManager;
        private final Map<UUID, String> clients = new HashMap<>();
        private final Map<UUID, String> warehouses = new HashMap<>();
        private final Map<UUID, String> colors = new HashMap<>();
        private final Map<UUID, String> units = new HashMap<>();
        private final Map<UUID, GoodsIdentity> goods = new HashMap<>();

        private NameDirectory(EntityManager entityManager) {
            this.entityManager = entityManager;
        }

        private String client(UUID id) {
            return name(clients, id, "SELECT name FROM clients WHERE id=:id");
        }

        private String warehouse(UUID id) {
            return name(warehouses, id, "SELECT name FROM warehouses WHERE id=:id");
        }

        private String color(UUID id) {
            return name(colors, id, "SELECT name FROM colors WHERE id=:id");
        }

        private String unit(UUID id) {
            return name(units, id, "SELECT name FROM units WHERE id=:id");
        }

        private String name(Map<UUID, String> cache, UUID id, String sql) {
            if (id == null) return null;
            if (cache.containsKey(id)) return cache.get(id);
            List<?> rows = entityManager.createNativeQuery(sql)
                    .setParameter("id", id)
                    .setMaxResults(1)
                    .getResultList();
            String value = rows.isEmpty() || rows.getFirst() == null
                    ? null : rows.getFirst().toString();
            cache.put(id, value);
            return value;
        }

        private GoodsIdentity goods(UUID id) {
            if (id == null) return GoodsIdentity.EMPTY;
            GoodsIdentity cached = goods.get(id);
            if (cached != null) return cached;
            List<?> rows = entityManager.createNativeQuery("""
                            SELECT code,name,stock_place
                            FROM goods
                            WHERE id=:id
                            """)
                    .setParameter("id", id)
                    .setMaxResults(1)
                    .getResultList();
            GoodsIdentity value = rows.isEmpty()
                    ? GoodsIdentity.EMPTY : GoodsIdentity.from(rows.getFirst());
            goods.put(id, value);
            return value;
        }
    }

    private record GoodsIdentity(String code, String name, String stockPlaceHint) {
        private static final GoodsIdentity EMPTY = new GoodsIdentity(null, null, null);

        private static GoodsIdentity from(Object raw) {
            Object[] values = (Object[]) raw;
            return new GoodsIdentity(
                    text(values[0]),
                    text(values[1]),
                    text(values[2]));
        }

        private static String text(Object value) {
            return value == null ? null : value.toString();
        }
    }
}
