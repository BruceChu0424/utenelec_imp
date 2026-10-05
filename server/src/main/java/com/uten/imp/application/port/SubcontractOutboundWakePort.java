package com.uten.imp.application.port;

import java.util.Collection;
import java.util.UUID;

/**
 * ADR-143 委外领料「重算可领」的唤醒入口(ADR-017 跨 feature 只经 port)。
 *
 * <p>库存内核 {@code StockService.recordMovementInternal} 每记一笔入库方向流水(含出库红冲把货冲回仓)
 * 就登记本次入库的维度, 在同一事务提交前调用本端口; 委外模块自己在预留释放(撤回领料、仓库改少、
 * 仓库退回领料、结束领料、订货红冲)、财务批准、改量之后也调用它; 回厂/退货/损耗结案这类只改变
 * 订货明细结清状态的事实按订货明细调用 {@link #enqueueDrawRecheckForOrderItems}。
 *
 * <p>实现只在当前事务里追加一条 {@code SUBCONTRACT_DRAW_RECHECK} outbox 事件(载荷 = 物料货色,
 * 去重键含事务号与物料维度), 不读齐套数据、不加锁、不发通知。真正的「可领多少」在 outbox 投递时
 * (事务已提交)才计算, 因此最后提交的那笔事务一定能看到此前所有已提交的到货, 不会漏提醒。
 */
public interface SubcontractOutboundWakePort {

    /** 本次入库或释放真正影响到的一个库存维度: 货品 + 颜色 + 仓(仓只作记录, 重算按货色)。 */
    record StockedDimension(UUID goodsId, UUID colorId, UUID warehouseId) {}

    /**
     * 为这些物料维度追加「领料重算」outbox 事件(同一事务、同一货色只追加一次)。
     * 实现须在调用方事务内执行(MANDATORY), 失败即整笔回滚, 不可吞错。
     */
    void enqueueDrawRecheck(Collection<StockedDimension> dimensions);

    /**
     * 按订货明细追加「领料重算」outbox 事件(载荷 {@code orderItemIds}): 回厂、委外退货、损耗结案的审核或红冲,
     * 以及订货结案重算、改量、仓库整张退回领料之后调用。这些事实不动物料库存, 按物料唤醒找不到委外件
     * 自己的明细; 投递时按实时数据重算这些明细的可领量并重置提醒水位(结清即收卡, 重新打开再提醒)。
     * 同一事务同一组明细只追加一次; 实现须在调用方事务内执行(MANDATORY), 失败即整笔回滚。
     */
    void enqueueDrawRecheckForOrderItems(Collection<UUID> orderItemIds);
}
