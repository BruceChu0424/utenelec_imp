package com.uten.imp.features.master.warehouse;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 仓库查询范围展开 + 叶子仓落库校验（V476 主/子层级）。
 *
 * <p>选择父仓查询 = 父仓自身 + 全部未软删后代聚合。库存看盘类查询（即时库存/
 * 余额/流水）经 {@link #scopeOf} 把单个 warehouseId 展开成仓库集合；叶子仓返回
 * 单元素集合（与旧精确匹配语义等价）。仓库量级个位数，全量载入内存建子树即可，
 * 无需递归 SQL。
 *
 * <p>反向约束（运营红线）：单据/收发存的仓库必须落到具体叶子仓——主仓库只是
 * 查询聚合与下拉分组，不允许在它名下记账；由 {@link #requireLeafWarehouse}
 * 在各单据保存路径硬校验（前端下拉同口径把父仓置灰）。
 */
@Service
@RequiredArgsConstructor
public class WarehouseScopeService {

    private final WarehouseRepository repo;

    /** Physical leaf warehouses sharing the selected warehouse's top-level owner. */
    @Transactional(readOnly = true)
    public Set<UUID> operationalLeafIds(UUID warehouseId) {
        if (warehouseId == null) return Set.of();
        List<Warehouse> all = activeWarehouses();
        Map<UUID, Warehouse> byId = new HashMap<>();
        Set<UUID> parents = new HashSet<>();
        for (Warehouse warehouse : all) {
            byId.put(warehouse.getId(), warehouse);
            if (warehouse.getParentId() != null) parents.add(warehouse.getParentId());
        }
        UUID mainId = mainWarehouseId(warehouseId, byId);
        if (mainId == null) return Set.of(warehouseId);
        Set<UUID> result = new LinkedHashSet<>();
        for (Warehouse warehouse : all) {
            if (!parents.contains(warehouse.getId())
                    && mainId.equals(mainWarehouseId(warehouse.getId(), byId))) {
                result.add(warehouse.getId());
            }
        }
        return Set.copyOf(result);
    }

    @Transactional(readOnly = true)
    public UUID mainWarehouseId(UUID warehouseId) {
        Map<UUID, Warehouse> byId = new HashMap<>();
        activeWarehouses().forEach(warehouse -> byId.put(warehouse.getId(), warehouse));
        return mainWarehouseId(warehouseId, byId);
    }

    /** One query snapshot for projections with many material allocations. */
    @Transactional(readOnly = true)
    public Map<UUID, UUID> mainWarehouseIds() {
        Map<UUID, Warehouse> byId = new HashMap<>();
        activeWarehouses().forEach(warehouse -> byId.put(warehouse.getId(), warehouse));
        Map<UUID, UUID> result = new HashMap<>();
        for (UUID id : byId.keySet()) {
            UUID main = mainWarehouseId(id, byId);
            if (main != null) result.put(id, main);
        }
        return Map.copyOf(result);
    }

    @Transactional(readOnly = true)
    public boolean sameMainWarehouse(UUID left, UUID right) {
        if (left == null || right == null) return false;
        if (left.equals(right)) return true;
        Map<UUID, Warehouse> byId = new HashMap<>();
        activeWarehouses().forEach(warehouse -> byId.put(warehouse.getId(), warehouse));
        UUID mainId = mainWarehouseId(left, byId);
        return mainId != null && mainId.equals(mainWarehouseId(right, byId));
    }

    private static UUID mainWarehouseId(UUID warehouseId, Map<UUID, Warehouse> byId) {
        Set<UUID> visited = new HashSet<>();
        UUID current = warehouseId;
        while (current != null && visited.add(current)) {
            Warehouse warehouse = byId.get(current);
            if (warehouse == null) return null;
            if (warehouse.getParentId() == null) return current;
            current = warehouse.getParentId();
        }
        return null;
    }

    /**
     * warehouseId 的查询范围：自身 + 全部未软删后代。
     * id 未知或已软删（历史余额可能仍引用）时退化为精确单仓集合，等价旧语义。
     */
    @Transactional(readOnly = true)
    public Set<UUID> scopeOf(UUID warehouseId) {
        if (warehouseId == null) {
            return Set.of();
        }
        List<Warehouse> all = activeWarehouses();
        Map<UUID, List<UUID>> children = new HashMap<>();
        Set<UUID> known = new HashSet<>();
        for (Warehouse w : all) {
            known.add(w.getId());
            if (w.getParentId() != null) {
                children.computeIfAbsent(w.getParentId(), k -> new ArrayList<>()).add(w.getId());
            }
        }
        if (!known.contains(warehouseId)) {
            return Set.of(warehouseId);
        }
        Set<UUID> scope = new LinkedHashSet<>();
        Deque<UUID> queue = new ArrayDeque<>();
        queue.add(warehouseId);
        while (!queue.isEmpty()) {
            UUID current = queue.poll();
            if (!scope.add(current)) continue;
            queue.addAll(children.getOrDefault(current, List.of()));
        }
        return scope;
    }

    /**
     * 运营落库校验：label（如「仓库」「调入仓」）对应的仓库必须是叶子仓。
     * 父仓（有子仓）只作查询聚合，不能作为单据记账对象。
     */
    @Transactional(readOnly = true)
    public void requireLeafWarehouse(UUID warehouseId, String label) {
        if (warehouseId == null) return;
        String parentName = null;
        boolean isParent = false;
        for (Warehouse w : activeWarehouses()) {
            if (warehouseId.equals(w.getParentId())) {
                isParent = true;
            } else if (warehouseId.equals(w.getId())) {
                parentName = w.getName();
            }
        }
        if (isParent) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    label + "必须选择具体子仓库，主仓库「"
                            + (parentName == null ? warehouseId : parentName)
                            + "」只用于汇总查询");
        }
    }

    /** Editing unrelated fields must not invalidate a historical storage identity. */
    @Transactional
    public void requireNewLeafSelection(UUID previousId, UUID requestedId, String label) {
        if (previousId != null && previousId.equals(requestedId)) {
            requireLeafWarehouse(requestedId, label);
        } else {
            requireActiveLeafWarehouse(requestedId, label);
        }
    }

    /** New selections/inbound require an enabled accounting leaf and enabled ancestry.
     * Existing proven stock issues deliberately continue using their original location. */
    @Transactional
    public void requireActiveLeafWarehouse(UUID warehouseId, String label) {
        if (warehouseId == null) return;
        Map<UUID, Warehouse> byId = new HashMap<>();
        Set<UUID> parents = new HashSet<>();
        for (Warehouse warehouse : activeWarehouses()) {
            if (warehouse.isDeleted()) continue;
            byId.put(warehouse.getId(), warehouse);
            if (warehouse.getParentId() != null) parents.add(warehouse.getParentId());
        }
        Set<UUID> path = new HashSet<>();
        UUID ancestorId = warehouseId;
        while (ancestorId != null && path.add(ancestorId)) {
            Warehouse ancestor = byId.get(ancestorId);
            ancestorId = ancestor == null ? null : ancestor.getParentId();
        }
        // Lock only this ancestry; unrelated warehouses remain independent.
        Map<UUID, Warehouse> locked = new HashMap<>();
        for (Warehouse warehouse : repo.findAllForNewSelection(path)) {
            if (!warehouse.isDeleted()) locked.put(warehouse.getId(), warehouse);
        }
        byId = locked;
        Warehouse selected = byId.get(warehouseId);
        if (selected == null || !selected.isAccountable()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    label + "不存在、已删除或不参与库存记账，请重新选择");
        }
        if (parents.contains(warehouseId)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    label + "必须选择具体子仓库，主仓库只用于汇总查询");
        }
        Set<UUID> visited = new HashSet<>();
        Warehouse current = selected;
        while (current != null && visited.add(current.getId())) {
            if ("禁用".equals(current.getStatus())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        label + "或所属主仓已停用，请选择其他启用仓库");
            }
            if (current.getParentId() == null) return;
            current = byId.get(current.getParentId());
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED,
                label + "的所属主仓不完整，请先修正仓库资料");
    }

    private List<Warehouse> activeWarehouses() {
        List<Warehouse> all = new ArrayList<>();
        for (Warehouse w : repo.findAll()) {
            if (!w.isDeleted()) all.add(w);
        }
        return all;
    }
}
