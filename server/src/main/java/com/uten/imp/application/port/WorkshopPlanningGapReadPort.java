package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 车间任务里「计划还没下单」的缺料(ADR-117)，只读。
 *
 * <p>判据复用物料分析尚未落实供给量：车间任务的某种物料还没备齐(缺口桶 SHORT /
 * SHORT_MAKE)，<b>并且</b>对应分析行的 planningUncoveredQty &gt; 0，说明计划仍需下单或认领公共在途。
 * 仅可认领的公共在途不等于本任务已有供给。只缺货但计划已经下过单或已认领的(在途、在产)
 * 不算，那是「等到货 / 等子件做完」。
 *
 * <p>没有物料分析来源的车间任务(手工计划、品质补产等)不给出任何缺口：没有可对照的计划口径，
 * 不猜。同理，任务里由追加用料申请(V702)或品质补料周期生成的需求不在物料分析里，也不参与。
 */
public interface WorkshopPlanningGapReadPort {

    /**
     * 按车间任务批量取缺口(给车间任务列表 / 物料表显示用)：同一物料分析的完整视图最多复用
     * 二十来秒内算过的那份——计划员刚下完单，车间最多晚这么一会儿看到「等计划下单」消失。
     */
    PlanningGaps planningGaps(Collection<UUID> segmentIds);

    /** 同上但一律当场重算：催计划、核对办结这类要落事实的地方用。 */
    PlanningGaps freshPlanningGaps(Collection<UUID> segmentIds);

    /**
     * 一批车间任务的缺口。
     *
     * @param gaps    有缺口的任务 → 按物料(货品 + 颜色 + 单位)一条
     * @param unknown 物料分析此刻读不出来(比如 BOM 变了要重新分析)的任务：既不能说「计划还没下单」，
     *                也不能说「计划已经下过单」，调用方要按「不知道」处理(不催、不办结)
     */
    record PlanningGaps(Map<UUID, List<Gap>> gaps, Set<UUID> unknown) {
        public static final PlanningGaps NONE = new PlanningGaps(Map.of(), Set.of());

        public PlanningGaps {
            gaps = gaps == null ? Map.of() : Map.copyOf(gaps);
            unknown = unknown == null ? Set.of() : Set.copyOf(unknown);
        }

        public List<Gap> of(UUID segmentId) {
            return gaps.getOrDefault(segmentId, List.of());
        }

        public boolean isUnknown(UUID segmentId) {
            return unknown.contains(segmentId);
        }
    }

    /**
     * 一种计划还没下够单的物料(同一任务里同一货品 / 颜色 / 单位的普通需求合成一条)。
     *
     * @param demandGapQty   这份缺口落到本任务哪几条需求上、各多少(按需求顺序逐条填到它自己的缺口为止)，
     *                       物料表逐行显示用；合计 = {@code gapQty}
     * @param gapQty         计划还需落实的供给量(基本单位)：取对应分析行 planningUncoveredQty 之和，
     *                       再封顶到本任务这种物料自己的缺口，不会大于本任务真正还缺的量
     * @param route          物料分析里这一行的供应方式(BUY / SUBCONTRACT / MAKE)；还没选时是建议值
     * @param routeConfirmed 计划有没有确认过供应方式；没确认说明连「怎么供」都还没定
     */
    record Gap(
            UUID segmentId,
            UUID analysisId,
            UUID materialLineId,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal gapQty,
            Map<UUID, BigDecimal> demandGapQty,
            String route,
            boolean routeConfirmed) {
    }
}
