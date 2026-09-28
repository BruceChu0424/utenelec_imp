package com.uten.imp.features.stock.weight;

/**
 * 库存流水重量的来历(ADR-135 仓库重量账, stock_movements.weight_source)。
 *
 * <p>可信度从高到低(见 {@link #distrustRank()}): 实称 > 按比例分摊(来源单据切片) > 按数量精确换算 > 按库存均重
 * > 按单重估算。红冲镜像多行时取其中最不可信的一种; 老数据有重量但没有来历的按实称读。
 */
public enum WeightSource {
    /** 仓库实称。 */
    MEASURED,
    /** 按数量精确换算(货品或行单位本身就是重量单位)。 */
    EXACT,
    /** 按来源单据的实称重量累计切片分摊(IQC 放行、成品登记、退货质检)。 */
    SLICE,
    /** 按本仓库存均重折算(估算)。 */
    AVERAGE,
    /** 按学习到的单重估算。 */
    ESTIMATE;

    /** 可信度名次: 越大越不可信(实称 0 < 切片 1 < 精确 2 < 均重 3 < 估算 4)。 */
    public int distrustRank() {
        return switch (this) {
            case MEASURED -> 0;
            case SLICE -> 1;
            case EXACT -> 2;
            case AVERAGE -> 3;
            case ESTIMATE -> 4;
        };
    }

    /** 是否估算值(入库带进来会让余额重量变成「≈」)。 */
    public boolean estimated() {
        return this == AVERAGE || this == ESTIMATE;
    }

    /** 两种来历里更不可信的一种; 任一为空取另一个。 */
    public static WeightSource weakest(WeightSource a, WeightSource b) {
        if (a == null) return b;
        if (b == null) return a;
        return a.distrustRank() >= b.distrustRank() ? a : b;
    }

    /** 按名次还原(库里聚合出的最大名次)。 */
    public static WeightSource ofDistrustRank(int rank) {
        for (WeightSource source : values()) {
            if (source.distrustRank() == rank) return source;
        }
        throw new IllegalArgumentException("unknown weight source rank " + rank);
    }

    /** 读库列: 空值返回 null; 老数据有重量没来历时由调用方按 MEASURED 处理。 */
    public static WeightSource fromColumn(String value) {
        return value == null || value.isBlank() ? null : valueOf(value.trim());
    }
}
