package com.uten.imp.features.stock;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;
import java.util.Collection;
import java.util.List;
import java.util.Set;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/**
 * 货品「归属仓」入库自动回写（2026-09-15 用户口径，V590 单一事实源）。
 *
 * <p>普通仓库入库把该货品的归属仓自动更新为最新入库仓；车间直送在线边位置的
 * 技术入库只记在制流转，不改变正常存放仓。调用方是
 * {@link StockService}——它是唯一库存过账内核，采购入库 / 委外回厂 / 完工入库 /
 * 调拨入 / 退料 / 盘盈 / 手工单全部入库路径都在那里收口，无旁路遗漏。
 * 出库与红冲（反方向流水）不翻转归属仓；红冲后再入库自然纠正。
 *
 * <p>多仓并存时归属仓 = 最新入库仓（哪仓最新收过这批货）；按仓真实库存仍以
 * stock_balances / 即时库存为准。值没变时不写（避免无谓的 goods 审计行）。
 */
@Service
@RequiredArgsConstructor
public class GoodsOwningWarehouseSyncService {

    private final JdbcTemplate jdbc;
    private static final Object POSTING_GOODS = new Object();

    /** Called after the existing source/inventory/warehouse/analysis prefix, before first inbound. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockForPosting(InventoryMutationLock inventoryLocks) {
        PostingGoods state = (PostingGoods) TransactionSynchronizationManager.getResource(POSTING_GOODS);
        if (state != null) {
            if (state.closed) throw changedScope();
            if (state.locked) return;
        }
        List<InventoryKey> scope = inventoryLocks.reacquirePostingScope();
        if (state != null && !state.inventory.equals(Set.copyOf(scope))) throw changedScope();
        List<UUID> ids = scope.stream().map(InventoryKey::goodsId).distinct()
                .sorted(com.uten.imp.common.util.PostgresUuidOrder.INSTANCE).toList();
        jdbc.queryForList("SELECT id FROM goods WHERE id = ANY(CAST(string_to_array(?, ',') AS uuid[]))"
                + " ORDER BY id FOR UPDATE", UUID.class,
                ids.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(",")));
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()) return;
        if (state == null) {
            state = new PostingGoods(Set.copyOf(scope), Set.copyOf(ids));
            TransactionSynchronizationManager.bindResource(POSTING_GOODS, state);
            TransactionSynchronizationManager.registerSynchronization(state);
        }
        state.locked = true;
    }

    /** Reject late goods before acquiring another inventory mutex while goods rows are held. */
    static void requireDeclaredInventory(Collection<InventoryKey> keys) {
        PostingGoods state = (PostingGoods) TransactionSynchronizationManager.getResource(POSTING_GOODS);
        if (state != null && (state.closed || !state.inventory.containsAll(keys))) {
            throw changedScope();
        }
    }

    private static ApiException changedScope() {
        return new ApiException(ErrorCode.CONFLICT, "入库货品在开始写入后发生变化，请刷新后重新提交完整批次");
    }

    private static final class PostingGoods implements TransactionSynchronization {
        final Set<InventoryKey> inventory;
        final Set<UUID> goods;
        final com.uten.imp.common.concurrency.SavepointSnapshots<Boolean> savepoints =
                new com.uten.imp.common.concurrency.SavepointSnapshots<>();
        boolean locked;
        boolean closed;
        PostingGoods(Set<InventoryKey> inventory, Set<UUID> goods) { this.inventory = inventory; this.goods = goods; }
        @Override public int getOrder() { return org.springframework.core.Ordered.HIGHEST_PRECEDENCE; }
        @Override public void suspend() {
            if (TransactionSynchronizationManager.getResource(POSTING_GOODS) == this) {
                TransactionSynchronizationManager.unbindResource(POSTING_GOODS);
            }
        }
        @Override public void resume() { if (!closed) TransactionSynchronizationManager.bindResource(POSTING_GOODS, this); }
        @Override public void savepoint(Object savepoint) { savepoints.record(savepoint, locked); }
        @Override public void savepointRollback(Object savepoint) {
            if (savepoints.rollback(savepoint) == null) {
                closed = true;
                if (TransactionSynchronizationManager.getResource(POSTING_GOODS) == this) {
                    TransactionSynchronizationManager.unbindResource(POSTING_GOODS);
                }
            }
            locked = false;
        }
        @Override public void afterCommit() { closed = true; savepoints.clear(); }
        @Override public void afterCompletion(int status) {
            closed = true;
            savepoints.clear();
            if (TransactionSynchronizationManager.getResource(POSTING_GOODS) == this) {
                TransactionSynchronizationManager.unbindResource(POSTING_GOODS);
            }
        }
    }

    /**
     * 入库方向回写。幂等且失败安全：货品不存在/仓库为空时静默跳过（过账流水
     * 本身已成功，归属回写绝不反过来阻断入库）。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncOnInbound(UUID goodsId, UUID warehouseId) {
        if (goodsId == null || warehouseId == null) {
            return;
        }
        if (TransactionSynchronizationManager.isActualTransactionActive()) {
            PostingGoods scope = (PostingGoods) TransactionSynchronizationManager.getResource(POSTING_GOODS);
            if (scope == null || scope.closed || !scope.locked || !scope.goods.contains(goodsId)) throw changedScope();
        }
        jdbc.update("""
                UPDATE goods goods
                SET owning_warehouse_id = warehouse.id,
                    version = goods.version + 1,
                    updated_at = now(),
                    updated_by = NULLIF(current_setting('app.actor_id', true), '')::uuid
                FROM warehouses warehouse
                WHERE warehouse.id = ?
                  AND NOT warehouse.is_line_side
                  AND NOT warehouse.is_deleted
                  AND goods.id = ?
                  AND NOT goods.is_deleted
                  AND goods.owning_warehouse_id IS DISTINCT FROM warehouse.id
                """, warehouseId, goodsId);
    }
}
