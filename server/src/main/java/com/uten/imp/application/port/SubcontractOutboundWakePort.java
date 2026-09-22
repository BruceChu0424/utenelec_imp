package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * ADR-101 委外出仓「到货即解锁」：仓库把货真正入库之后，回头叫醒在等这批货的委外发料计划
 * (ADR-017 跨 feature 只经 port)。
 *
 * <p>在此之前，委外订货一经财务批准就按整笔订货量给仓库开一张满量出仓草稿，子件还在采购
 * 路上也照开；仓库拣不出货，保存时才被「合格可动用库存不足」打回。现在改成：批准时没货就
 * 不开草稿(任务停在「等子件到货」)，等这一批货真入库，由本端口按当时的可动用量开一张
 * 能发得出去的草稿并通知仓库——用户口径「只要那个子件入库了，不管数量多少，委外就解锁，
 * 可以分批发货」。
 *
 * <p>幂等：同一维度重复叫醒不会重复开草稿(该计划行已有未审草稿就跳过)，所以入库重放、
 * 一次入库命中多行、以及后续每一批到货都可以安全地再调一次。
 */
public interface SubcontractOutboundWakePort {

    /** 本次入库真正落到库存的一个维度：货品 + 颜色 + 实收仓。 */
    record StockedDimension(UUID goodsId, UUID colorId, UUID warehouseId) {}

    /**
     * 按本次入库的维度叫醒等料的委外出仓计划行：补出仓草稿(数量按该仓此刻的合格可动用量
     * 截断)并给仓库发「现在可以发料了」。调用方须在写完库存的同一事务里调用。
     */
    void wakeOutboundAfterStockIn(List<StockedDimension> dimensions);
}
