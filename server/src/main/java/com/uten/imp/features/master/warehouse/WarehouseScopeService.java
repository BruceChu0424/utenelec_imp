package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseUse;
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
 * <p>反向约束(运营红线)：单据/收发存的仓库必须落到具体子仓——主仓库只是
 * 查询聚合与下拉分组，不允许在它名下记账。各单据保存/审核路径一律经 {@link #require}
 * 按用途(良品入/良品出/转入不良/不良转出/处置出库/调拨/盘点, ADR-146)校验, 判定规则只在
 * {@link WarehouseUsePolicy} 一处; 前端选仓面板按同一用途过滤。
 */
@Service
@RequiredArgsConstructor
public class WarehouseScopeService {

    private final WarehouseRepository repo;

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
     * 新选一个仓(ADR-146): label(如「入库仓库」「调出仓」)对应的仓必须是启用中的记账子仓,
     * 且仓库用途(良品仓/不良品仓)符合 use。锁住它的祖先链直到本事务结束, 与停用/改用途互斥。
     */
    @Transactional
    public void require(UUID warehouseId, String label, WarehouseUse use) {
        requireSelection(warehouseId, label, use, true);
    }

    /**
     * 编辑单据时的选仓: 沿用原来的仓(previousId 与 warehouseId 相同)不再要求它仍启用——历史身份不变;
     * 换了仓按新选处理。两种情况都要求是记账子仓且仓库用途符合 use。
     */
    @Transactional
    public void require(UUID previousId, UUID warehouseId, String label, WarehouseUse use) {
        requireSelection(warehouseId, label, use, previousId == null || !previousId.equals(warehouseId));
    }

    /** 仓库用途: true = 不良品仓。不存在的仓按良品仓(由 {@link #require} 另行报不存在)。 */
    @Transactional(readOnly = true)
    public boolean isDefective(UUID warehouseId) {
        if (warehouseId == null) return false;
        return repo.findById(warehouseId).map(Warehouse::isDefective).orElse(false);
    }

    /** Only the verified workshop direct-transfer lane may post to this location. */
    @Transactional
    public void requireActiveLineSideWarehouse(UUID warehouseId, String label) {
        if (warehouseId == null) return;
        WarehouseUsePolicy.Facts facts = facts(warehouseId, true);
        if (facts == null || !facts.accountable()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    label + "不存在、已删除或不参与库存记账，请重新选择");
        }
        if (!facts.lineSide()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "必须是本次车间直送的流转位置");
        }
        if (facts.parent()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    label + "必须选择具体子仓库，主仓库只用于汇总查询");
        }
        if (!facts.chainComplete()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "的所属主仓不完整，请先修正仓库资料");
        }
        if (!facts.chainActive()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "或所属主仓已停用，请选择其他启用仓库");
        }
    }

    private void requireSelection(UUID warehouseId, String label, WarehouseUse use, boolean requireActive) {
        if (warehouseId == null) return;
        String violation = WarehouseUsePolicy.violation(facts(warehouseId, requireActive), label, use, requireActive);
        if (violation != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, violation);
        }
    }

    /**
     * 组装一个仓的选择事实。新选(lock=true)时锁住它的祖先链(只锁这一条链, 其余仓互不影响),
     * 状态与层级以锁后的行为准; 沿用原仓只读快照。仓不存在或已删除返回 null。
     */
    private WarehouseUsePolicy.Facts facts(UUID warehouseId, boolean lock) {
        List<Warehouse> all = activeWarehouses();
        boolean parent = false;
        boolean lineSideWithChild = false;
        Map<UUID, Warehouse> byId = new HashMap<>();
        for (Warehouse warehouse : all) {
            byId.put(warehouse.getId(), warehouse);
            if (warehouseId.equals(warehouse.getParentId())) {
                if (!warehouse.isLineSide()) parent = true;
                lineSideWithChild = true;
            }
        }
        if (lock) {
            byId.putAll(lockedAncestry(warehouseId, byId));
        }
        Warehouse selected = byId.get(warehouseId);
        if (selected == null || selected.isDeleted()) return null;
        boolean complete = false;
        boolean active = true;
        Set<UUID> visited = new HashSet<>();
        Warehouse current = selected;
        while (current != null && visited.add(current.getId())) {
            if ("禁用".equals(current.getStatus())) active = false;
            if (current.getParentId() == null) {
                complete = true;
                break;
            }
            current = byId.get(current.getParentId());
        }
        return new WarehouseUsePolicy.Facts(selected.getName(), selected.isAccountable(), selected.isLineSide(),
                selected.isDefective(), parent || (selected.isLineSide() && lineSideWithChild), complete, active);
    }

    private Map<UUID, Warehouse> lockedAncestry(UUID warehouseId, Map<UUID, Warehouse> byId) {
        Set<UUID> path = new HashSet<>();
        UUID ancestorId = warehouseId;
        while (ancestorId != null && path.add(ancestorId)) {
            Warehouse ancestor = byId.get(ancestorId);
            ancestorId = ancestor == null ? null : ancestor.getParentId();
        }
        Map<UUID, Warehouse> locked = new HashMap<>();
        for (Warehouse warehouse : repo.findAllForNewSelection(path)) {
            if (!warehouse.isDeleted()) locked.put(warehouse.getId(), warehouse);
        }
        // 锁后才发现已删除的祖先: 从快照里拿掉, 链就不完整。
        for (UUID id : path) {
            if (!locked.containsKey(id)) byId.remove(id);
        }
        return locked;
    }

    private List<Warehouse> activeWarehouses() {
        List<Warehouse> all = new ArrayList<>();
        for (Warehouse w : repo.findAll()) {
            if (!w.isDeleted()) all.add(w);
        }
        return all;
    }
}
