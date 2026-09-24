package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间任务里「计划还没下单」的缺料(ADR-117)，只读。
 *
 * <p>判据与物料分析主表的「还缺数量」是同一个数：车间任务的某种物料还没备齐(缺口桶 SHORT /
 * SHORT_MAKE)，<b>并且</b>它在物料分析里对应的那一行此刻还缺(netShortageQty &gt; 0)，就说明计划还没
 * 为它下够单——采购 / 委外还没下达、或自制子件还没排计划。只缺货但计划已经下过单的(在途、在产)
 * 不算，那是「等到货 / 等子件做完」。
 *
 * <p>没有物料分析来源的车间任务(手工计划、品质补产等)不给出任何缺口：没有可对照的计划口径，
 * 不猜。
 */
public interface WorkshopPlanningGapReadPort {

    /**
     * 按车间任务批量取缺口。只返回有缺口的任务；每个任务内按物料一条。
     * 同一物料分析在一次调用里只算一次。
     */
    Map<UUID, List<Gap>> planningGaps(Collection<UUID> segmentIds);

    /**
     * 一种计划还没下够单的物料。
     *
     * @param gapQty         计划这边还差多少没下单(基本单位)：取物料分析那一行的「还缺数量」，
     *                       再封顶到本任务这种物料自己的缺口，不会大于本任务真正还缺的量
     * @param route          物料分析里这一行的供应方式(BUY / SUBCONTRACT / MAKE)；还没选时是建议值
     * @param routeConfirmed 计划有没有确认过供应方式；没确认说明连「怎么供」都还没定
     */
    record Gap(
            UUID segmentId,
            UUID demandId,
            UUID analysisId,
            UUID materialLineId,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal gapQty,
            String route,
            boolean routeConfirmed) {
    }
}
