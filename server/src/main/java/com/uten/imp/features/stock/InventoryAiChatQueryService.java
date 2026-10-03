package com.uten.imp.features.stock;

import com.uten.imp.application.port.WarehouseInventoryReferencePort;
import com.uten.imp.application.port.WarehouseInventoryReferencePort.WarehouseReference;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** Bounded, quantity-only projection using the inventory page and the real warehouse issue gate. */
@Service
public class InventoryAiChatQueryService {
    static final int MAX_WAREHOUSES = 12;
    static final int MAX_GOODS_COLORS = 5;

    public record Request(String keyword, UUID warehouseId) {}
    public record Row(UUID goodsId, UUID colorId, UUID owningWarehouseId, UUID warehouseId,
                      String code, String name, String color, String unit, String warehouseName,
                      BigDecimal qty, BigDecimal reserved, BigDecimal movable,
                      BigDecimal pendingInspection, BigDecimal pendingStockIn) {}
    public record Facts(List<WarehouseReference> scope, List<Row> rows, String note) {}

    private final StockQueryService stock;
    private final StockBalanceRepository balances;
    private final StockReservationRepository reservations;
    private final WarehouseInventoryReferencePort references;
    private final WarehouseTaskScopePort scopes;
    private final AiChatAccessPolicy access;

    public InventoryAiChatQueryService(StockQueryService stock, StockBalanceRepository balances,
            StockReservationRepository reservations, WarehouseInventoryReferencePort references,
            WarehouseTaskScopePort scopes, AiChatAccessPolicy access) {
        this.stock = stock;
        this.balances = balances;
        this.reservations = reservations;
        this.references = references;
        this.scopes = scopes;
        this.access = access;
    }

    public boolean available() {
        try {
            AuthUser actor = access.requireChat();
            return access.hasDomain("WAREHOUSE")
                    && (actor.isSuperAdmin() || actor.getPermissions().contains("stock:view"));
        } catch (ApiException denied) { return false; }
    }

    /** One database snapshot keeps the page quantities and issue-gate claims mutually consistent. */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public Facts read(Request request) {
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN);
        AuthUser actor = access.requireChat();
        List<WarehouseReference> all = references.warehouses();
        Set<UUID> authorized;
        if (actor.isSuperAdmin()) {
            authorized = all.stream().map(WarehouseReference::id).collect(Collectors.toSet());
        } else {
            // MINE intentionally includes unassigned work. That inbox fallback is not an AI grant.
            authorized = subtree(all, references.assignedWarehouseRoots());
            var mine = scopes.resolve(WarehouseTaskScopePort.SCOPE_MINE, null);
            if (mine.active()) authorized.retainAll(mine.warehouseIds());
        }
        if (authorized.isEmpty()) return new Facts(List.of(), List.of(),
                "当前账号尚未分配可查询的负责仓库，请先由管理员维护仓库负责人；这不表示库存为零。");
        if (request.warehouseId() != null) {
            authorized.retainAll(subtree(all, Set.of(request.warehouseId())));
            if (authorized.isEmpty()) throw new ApiException(ErrorCode.FORBIDDEN,
                    "所选仓库不在你当前可查询的负责仓库范围内");
        }
        List<WarehouseReference> selected = all.stream().filter(w -> authorized.contains(w.id()))
                .filter(w -> w.accountable() && !w.lineSide())
                .sorted(Comparator.comparing(w -> w.id().toString())).toList();
        if (selected.isEmpty()) return new Facts(List.of(), List.of(),
                "当前范围没有可查询的核算仓库；车间内料仓不属于本次库存查询范围，不能据此判断库存为零。");
        if (selected.size() > MAX_WAREHOUSES) return new Facts(selected, List.of(),
                "当前可查询仓库较多，请指定一个仓库后再查询，最多一次查询 12 个实际仓库。");
        Set<UUID> ids = selected.stream().map(WarehouseReference::id).collect(Collectors.toSet());
        var matched = stock.instantInventoryRowsInWarehouseScope(filter(request.keyword(), null, null),
                ids, 1, MAX_GOODS_COLORS + 1, "name", "asc");
        if (matched.getTotal() > MAX_GOODS_COLORS) return new Facts(selected, List.of(),
                "匹配到的货品和颜色超过 5 种，请补充准确的物料编码或更完整的名称后再查询。");
        if (matched.getItems().isEmpty()) return new Facts(selected, List.of(),
                "当前范围未找到匹配的有效货品，请核对物料编码或名称；未找到不等于库存为零。");

        List<Row> rows = new ArrayList<>();
        for (InstantInventoryRow goods : matched.getItems()) {
            if (goods.getGoodsId() == null) throw changed();
            for (WarehouseReference warehouse : selected) {
                var page = stock.instantInventoryRowsInWarehouseScope(
                        filter(null, goods.getGoodsId(), goods.getColorId()), Set.of(warehouse.id()),
                        1, 2, "name", "asc");
                if (page.getTotal() != 1 || page.getItems().size() != 1) throw changed();
                InstantInventoryRow item = page.getItems().getFirst();
                if (!goods.getGoodsId().equals(item.getGoodsId())
                        || !Objects.equals(goods.getColorId(), item.getColorId())
                        || !Objects.equals(goods.getOwningWarehouseId(), item.getOwningWarehouseId())) throw changed();
                rows.add(new Row(item.getGoodsId(), item.getColorId(), item.getOwningWarehouseId(), warehouse.id(),
                        item.getGoodsCode(), item.getName(), item.getColorName(), item.getUnitName(), warehouse.name(),
                        quantity(item.getQty()), quantity(reservations.warehouseEffectiveReservedBase(
                                warehouse.id(), item.getGoodsId(), item.getColorId())),
                        quantity(balances.warehouseAvailableBase(warehouse.id(), item.getGoodsId(), item.getColorId())),
                        quantity(item.getPendingQty()), quantity(item.getPendingStockInQty())));
            }
        }
        rows.sort(Comparator.comparing((Row row) -> row.goodsId().toString())
                .thenComparing(row -> Objects.toString(row.colorId(), ""))
                .thenComparing(row -> row.warehouseId().toString()));
        return new Facts(selected, List.copyOf(rows), "");
    }

    private static StockQueryService.InstantInventoryFilter filter(String keyword, UUID goodsId, UUID colorId) {
        return new StockQueryService.InstantInventoryFilter(null, null, true, false, keyword,
                null, null, colorId, null, null, null, goodsId, goodsId != null && colorId == null, true);
    }

    private static Set<UUID> subtree(List<WarehouseReference> warehouses, Set<UUID> roots) {
        Set<UUID> known = warehouses.stream().map(WarehouseReference::id).collect(Collectors.toSet());
        Set<UUID> result = new HashSet<>(roots);
        result.retainAll(known);
        boolean added;
        do {
            added = false;
            for (WarehouseReference warehouse : warehouses) {
                if (warehouse.parentId() != null && result.contains(warehouse.parentId()))
                    added |= result.add(warehouse.id());
            }
        } while (added);
        return result;
    }

    private static BigDecimal quantity(BigDecimal value) {
        if (value == null) throw changed();
        return value.stripTrailingZeros();
    }

    private static ApiException changed() {
        return new ApiException(ErrorCode.FORBIDDEN, "库存对象或查询范围已变化，请重新查询");
    }
}
