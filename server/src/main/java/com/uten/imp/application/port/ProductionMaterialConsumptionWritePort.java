package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 生产日报审核时把「本次实际用料」转成材料消耗，红冲时原样退回。
 *
 * <p>调用方(生产日报审核/红冲)已经做完自己的状态、对象范围与并发校验；本端口的实现
 * 仍然独立校验材料动作权限与逐需求归属，不信任调用方的判断。
 *
 * <p>三个方法都要求已经处于调用方的事务里(MANDATORY)：报工量与材料消耗必须同生共死，
 * 任一失败整笔回滚，不允许出现「完工量加了、实耗没记」或反过来的半截状态。
 */
public interface ProductionMaterialConsumptionWritePort {

    /**
     * 按需求登记本次实际消耗。qtyBase 为 0 的行由实现直接丢弃(「这批料没用」不产生记账事实)。
     *
     * @param executionSegmentId 物料所属执行段；分批生产时可能是前批原领料段，不等于报工段
     */
    void consumeForDailyReport(
            UUID planId,
            UUID executionSegmentId,
            UUID dailyReportId,
            String idempotencyKey,
            String reason,
            List<ConsumptionLine> lines);

    /**
     * 收尾把该执行段当前全部可退余料提交退仓申请，返回生成的退料单张数(按原领料仓库拆单)。
     *
     * <p>必须在 {@link #consumeForDailyReport} 之后调用：退仓申请一提交就冻结领料过账额度，
     * 先冻后结会让实耗登记撞「超过准确原领料未耗用数量」。
     *
     * <p>没有可退量时返回 0，不生成任何单据、不打扰仓库。
     */
    int requestSurplusReturnForDailyReport(
            UUID planId,
            UUID executionSegmentId,
            UUID dailyReportId,
            String idempotencyKey,
            String reason);

    /**
     * 红冲该日报审核时登记的全部实耗。按结算事件上的日报来源反查，逐条按原过账冲销；
     * 该日报没登记过实耗时什么都不做。
     */
    void reverseDailyReportConsumption(
            UUID planId,
            UUID dailyReportId,
            String idempotencyKey,
            String reason);

    /** 一条需求的本次实际用料(基本量，与需求 unit_id 同口径)。 */
    record ConsumptionLine(UUID demandId, BigDecimal qtyBase) {
    }
}
