package com.uten.imp.features.stock;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 货品「归属仓」入库自动回写（2026-09-15 用户口径，V590 单一事实源）。
 *
 * <p>任何入库把该货品的归属仓自动更新为最新入库仓。调用方是
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

    /**
     * 入库方向回写。幂等且失败安全：货品不存在/仓库为空时静默跳过（过账流水
     * 本身已成功，归属回写绝不反过来阻断入库）。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncOnInbound(UUID goodsId, UUID warehouseId) {
        if (goodsId == null || warehouseId == null) {
            return;
        }
        jdbc.update(
                "UPDATE goods SET owning_warehouse_id = ? WHERE id = ? AND owning_warehouse_id IS DISTINCT FROM ?",
                warehouseId, goodsId, warehouseId);
    }
}
