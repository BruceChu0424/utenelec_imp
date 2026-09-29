package com.uten.imp.features.master.goods.dto;

import com.uten.imp.common.util.NativeValueConverters;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

/**
 * 一条组装边的真实使用数量与计算采用值(ADR-129)，逐列取自 {@code v_goods_bom_item_usage}：
 * 「按边给出计算用量」只在这个视图里定义一次，Java 只读不算。设计使用数量就是组装行的 qty。
 *
 * <p>组装信息页签({@link BomItemView})与「BOM 学习记录」的组件行都用这一个映射，JSON 里平铺成同名字段；
 * 学习记录里 BOM 外实际用过的料没有组装边，按 {@link #OFF_BOM_COLUMNS} 从 v_goods_bom_actual_usage 读同序的列。
 *
 * <p>真实使用数量按良品算；报工不良数只派生两个说明数(实产单耗与不良率)，不参与计算。
 *
 * @param actualQty            真实使用数量(该边自己的计量口径)；只有 actualStatus=ACTUAL 才有值，否则为空(绝不当 0)
 * @param actualPerUnitQty     每个父件基本单位的真实使用数量(组件基本单位)，不管该边计量方式；
 *                             没有数据或父件基本单位变了时为空
 * @param actualStatus         ACTUAL 可用 / NO_DATA 没有有效样本 / NOT_LINEAR 整包或固定批耗不能按平均单耗算 /
 *                             OUTPUT_UNIT_CHANGED 父件基本单位在学习后变了
 * @param effectiveQty         计算采用的用量(有真实用真实，否则设计)，6 位向上取整；BOM 外的料为空
 * @param usageBasis           ACTUAL / DESIGN；BOM 外的料为空
 * @param actualSampleCount    重新学习之后的有效批次数
 * @param actualOutputQty      重新学习之后用到该物料的累计产量(暴露产量，只含良品)
 * @param actualNetQty         重新学习之后的累计实物净耗料
 * @param systemLearned        系统学习边(由学习引擎新建，设计使用数量由系统同步)
 * @param actualDefectQty      重新学习之后用到该物料的批次的报工不良数(父件基本单位)；没有时为 0
 * @param actualPerProducedQty 实产单耗 = 净耗 / (良品 + 不良)，与 actualQty 同一计量口径；
 *                             只有 actualStatus=ACTUAL 才有值
 * @param actualDefectRate     不良率 = 不良 / (良品 + 不良)，0..1；这段累计里没有产出时为空
 */
public record BomItemUsage(
        BigDecimal actualQty,
        BigDecimal actualPerUnitQty,
        String actualStatus,
        BigDecimal effectiveQty,
        String usageBasis,
        long actualSampleCount,
        BigDecimal actualOutputQty,
        BigDecimal actualNetQty,
        OffsetDateTime actualUpdatedAt,
        OffsetDateTime relearnedAt,
        boolean systemLearned,
        BigDecimal actualDefectQty,
        BigDecimal actualPerProducedQty,
        BigDecimal actualDefectRate) {

    /** 视图(别名 u)里与本记录同序的列；查询把它拼在自己的列后面，再用 {@link #of} 从同一下标读回。 */
    public static final String COLUMNS = "u.actual_qty, u.actual_per_unit_qty, u.actual_status, u.effective_qty, "
            + "u.usage_basis, u.sample_count, u.exposure_output_qty, u.net_qty, u.actual_updated_at, "
            + "u.relearned_at, u.system_learned, u.defect_qty, u.actual_per_produced_qty, u.defect_rate";

    /**
     * 同序的列，取自 v_goods_bom_actual_usage(别名 a)：BOM 外的料没有边，真实使用数量与实产单耗都是每父件
     * 基本单位的数(非 ACTUAL 时视图已给空)，没有计算采用值，也不是系统学习边。
     */
    public static final String OFF_BOM_COLUMNS = "a.actual_qty, a.actual_qty, a.actual_status, NULL::numeric, "
            + "NULL::text, a.sample_count, a.exposure_output_qty, a.net_qty, a.updated_at, "
            + "a.relearned_at, false, a.defect_qty, a.actual_per_produced_qty, a.defect_rate";

    /** 视图里查不到这条边(只在尚未落库的行上出现)：不编造任何学习数据。 */
    public static final BomItemUsage NONE = new BomItemUsage(
            null, null, null, null, null, 0, null, null, null, null, false, BigDecimal.ZERO, null, null);

    /** 从原生查询行的第 {@code from} 列起按 {@link #COLUMNS} 的顺序读取。 */
    public static BomItemUsage of(Object[] row, int from) {
        return new BomItemUsage(
                decimal(row[from]),
                decimal(row[from + 1]),
                (String) row[from + 2],
                decimal(row[from + 3]),
                (String) row[from + 4],
                row[from + 5] == null ? 0 : ((Number) row[from + 5]).longValue(),
                decimal(row[from + 6]),
                decimal(row[from + 7]),
                NativeValueConverters.toOffsetDateTime(row[from + 8]),
                NativeValueConverters.toOffsetDateTime(row[from + 9]),
                Boolean.TRUE.equals(row[from + 10]),
                row[from + 11] == null ? BigDecimal.ZERO : decimal(row[from + 11]),
                decimal(row[from + 12]),
                decimal(row[from + 13]));
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : NativeValueConverters.toBigDecimal(value);
    }
}
