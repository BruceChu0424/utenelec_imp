package com.uten.imp.features.sales.shipment.warehouse;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemDto;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Maps the authoritative sales shipment state machine to a warehouse-only read model. */
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
                        null,
                        null),
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
        List<String> allowedTargets = source.isCanManageWarehouseWork()
                ? SalesShipmentService.allowedWarehouseTransitionTargets(
                        source.getWarehouseWorkStatus())
                : List.of();
        List<WarehouseSalesOutboundLine> lines = source.getItems().stream()
                .map(item -> toLine(item, names))
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
                lines);
    }

    private WarehouseSalesOutboundLine toLine(
            ShipmentItemDto source,
            NameDirectory names) {
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
                source.getSourceDocNo());
    }

    private static String normalize(String value) {
        if (value == null || value.isBlank()) return null;
        return value.trim().toUpperCase(java.util.Locale.ROOT);
    }

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
