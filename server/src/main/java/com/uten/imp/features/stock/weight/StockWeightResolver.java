package com.uten.imp.features.stock.weight;

import com.uten.imp.features.stock.StockService;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Supplier;

/**
 * 仓库重量账的纯计算(ADR-135 §2.3 / §2.4): 给定本维度加锁后的余额快照和上下文, 算出本笔流水的重量与来历、
 * 余额重量怎么变、要不要补「重量起算 / 尾差调整」行。没有 Spring、没有 IO, 全部场景由单测覆盖。
 *
 * <p>重量永远不挡数量过账: 任何算不出来的情况都落成「未知」(null), 不抛错。
 *
 * <p>账链约定(对账视图与流水面板共用): 按 ledger_seq 排序, 每条调整行的「前」等于上一行的「后」;
 * 本笔流水引起的「重量起算 / 尾差调整」都写在流水之前, 把余额纠正到「让这笔流水正好落在最终重量上」的数,
 * 所以流水行的「后」(balance_weight_after) 就是含纠正的最终余额重量, 且「前 +/- 本笔重量 = 后」逐行成立;
 * 最后一行的「后」等于 stock_balances.weight。原余额是负数量(老库负库存)时重量无从起算, 不写调整行,
 * 由流水行直接给出重新起算后的重量(估算)。
 */
public final class StockWeightResolver {

    /** 调拨入(与调出 8 成对, §2.3 COUNTERPART)。 */
    public static final short TYPE_TRANSFER_IN = 7;

    private static final BigDecimal ZERO_KG = BigDecimal.ZERO.setScale(WeightMath.SCALE);

    private StockWeightResolver() {
    }

    // ===== 输入与输出 =====

    /**
     * 本维度(仓库 x 货品 x 颜色)在库存锁下读到的事实。
     *
     * @param balanceQty       余额数量(没有余额行按 0)
     * @param balanceWeight    余额重量, null = 未知
     * @param balanceEstimated 余额重量是否估算
     * @param balanceExists    余额行是否存在(不存在按「0 数量 0 重量」, 不补起算行)
     * @param goodsMassFactor  货品基本单位本身是重量单位时每单位千克数(精确货品), 否则 null
     * @param lineMassFactor   本行单位本身是重量单位时每单位千克数, 否则 null
     * @param pool             同一来源行同一类型同一维度的既往流水合计(红冲镜像用), 没有来源时 null
     * @param counterpart      调拨入对应的调出流水重量, 不是调拨入时 null
     * @param unitWeight       货品级单重, 按需才查(返回 null = 没有)
     */
    public record WeightContext(
            BigDecimal balanceQty,
            BigDecimal balanceWeight,
            boolean balanceEstimated,
            boolean balanceExists,
            BigDecimal goodsMassFactor,
            BigDecimal lineMassFactor,
            Pool pool,
            Counterpart counterpart,
            Supplier<UnitWeightLookup.UnitWeightRef> unitWeight) {

        public WeightContext {
            balanceQty = balanceQty == null ? BigDecimal.ZERO : balanceQty;
            unitWeight = unitWeight == null ? () -> null : unitWeight;
        }

        /** 只有余额快照(没有上下文读取器的纯单测/兜底): 不精确换算、不镜像、不估算单重。 */
        public static WeightContext balanceOnly(BigDecimal qty, BigDecimal weight, boolean estimated, boolean exists) {
            return new WeightContext(qty, weight, estimated, exists, null, null, null, null, null);
        }

        /** 可用的货品级单重, 没有返回 null。 */
        public UnitWeightLookup.UnitWeightRef apw() {
            UnitWeightLookup.UnitWeightRef ref = unitWeight.get();
            return ref != null && ref.usable() ? ref : null;
        }
    }

    /** 同一来源键 K 上既往流水按方向的数量/重量合计; allKnown = 这些流水都有重量。 */
    public record Pool(BigDecimal inQty, BigDecimal outQty, BigDecimal inKg, BigDecimal outKg,
                       boolean allKnown, WeightSource weakest) {
        public Pool {
            inQty = inQty == null ? BigDecimal.ZERO : inQty;
            outQty = outQty == null ? BigDecimal.ZERO : outQty;
            inKg = inKg == null ? BigDecimal.ZERO : inKg;
            outKg = outKg == null ? BigDecimal.ZERO : outKg;
        }
    }

    /** 调拨入对应的调出流水: 重量与来历(老数据没来历按实称)。 */
    public record Counterpart(BigDecimal kg, WeightSource source) {
    }

    /** 一行只改重量的调整(起算 / 尾差), before = null 表示原来未知。 */
    public record AdjustmentDraft(String kind, BigDecimal before, BigDecimal after) {
        public static final String ANCHOR = "ANCHOR";
        public static final String RESIDUAL = "RESIDUAL";
        public static final String COUNT = "COUNT";
        public static final String MANUAL = "MANUAL";
        public static final String REVERSAL = "REVERSAL";

        public BigDecimal deltaKg() {
            return WeightMath.delta(before, after);
        }
    }

    /**
     * @param weightKg           本笔流水重量, null = 未知
     * @param source             本笔流水重量来历, 与 weightKg 同为空或同不空
     * @param before             流水之前按顺序要写的调整行(重量起算 / 尾差调整)
     * @param balanceWeightAfter 本笔过账后余额的最终重量(写 stock_balances.weight 与流水 balance_weight_after)
     * @param estimatedAfter     余额重量是否估算
     */
    public record WeightResolution(BigDecimal weightKg, WeightSource source, List<AdjustmentDraft> before,
                                   BigDecimal balanceWeightAfter, boolean estimatedAfter) {
        public WeightResolution {
            before = before == null ? List.of() : List.copyOf(before);
        }
    }

    /** 撤销一次盘点定重后的余额重量(§3.4)。 */
    public record CountReversal(BigDecimal weightAfter, boolean estimatedAfter) {
    }

    // ===== 流水重量 + 余额 =====

    public static WeightResolution resolve(WeightContext ctx, StockService.MovementRequest req) {
        Weighed weighed = movementWeight(ctx, req);
        return balance(ctx, req.qty(), req.direction() == StockService.DIR_IN, weighed.kg(), weighed.source());
    }

    private record Weighed(BigDecimal kg, WeightSource source) {
        static final Weighed UNKNOWN = new Weighed(null, null);
    }

    /** §2.3: 取第一条适用的规则。 */
    private static Weighed movementWeight(WeightContext ctx, StockService.MovementRequest req) {
        BigDecimal q = req.qty();
        boolean in = req.direction() == StockService.DIR_IN;
        // 1. 精确: 货品基本单位或本行单位本身就是重量单位。
        if (ctx.goodsMassFactor() != null) {
            return kept(WeightMath.times(q, ctx.goodsMassFactor()), WeightSource.EXACT);
        }
        if (ctx.lineMassFactor() != null) {
            return kept(WeightMath.lineUnitWeight(q, req.unitRate(), ctx.lineMassFactor()), WeightSource.EXACT);
        }
        // 2. 调拨入沿用对应调出的重量与来历。
        Counterpart counterpart = ctx.counterpart();
        if (in && req.movementType() == TYPE_TRANSFER_IN && counterpart != null && counterpart.kg() != null) {
            return kept(counterpart.kg(), counterpart.source() == null ? WeightSource.MEASURED : counterpart.source());
        }
        // 3. 红冲镜像: 同一来源行上还没冲完的原流水, 按数量比例取回; 最后一次取余, 分几次冲也分毫不差。
        Pool pool = ctx.pool();
        if (pool != null && pool.allKnown()) {
            BigDecimal open = in ? pool.outQty().subtract(pool.inQty()) : pool.inQty().subtract(pool.outQty());
            BigDecimal openKg = in ? pool.outKg().subtract(pool.inKg()) : pool.inKg().subtract(pool.outKg());
            if (open.signum() > 0 && q.compareTo(open) <= 0 && openKg.signum() >= 0) {
                BigDecimal kg = q.compareTo(open) == 0 ? WeightMath.round4(openKg) : WeightMath.prorate(openKg, q, open);
                return kept(kg, pool.weakest() == null ? WeightSource.MEASURED : pool.weakest());
            }
        }
        // 4. 调用方带来的实称/切片。
        if (req.weight() != null) {
            return kept(req.weight().kg(), req.weight().source());
        }
        BigDecimal qb = ctx.balanceQty();
        BigDecimal wb = ctx.balanceWeight();
        boolean averageKnown = wb != null && qb.signum() > 0;
        // 5. 出库: 本仓均重(发完取整数余额重量), 否则单重估算。
        if (!in) {
            if (averageKnown) {
                return kept(q.compareTo(qb) >= 0 ? wb : WeightMath.prorate(wb, q, qb), WeightSource.AVERAGE);
            }
            UnitWeightLookup.UnitWeightRef apw = ctx.apw();
            return apw == null ? Weighed.UNKNOWN : kept(WeightMath.times(q, apw.kgPerBaseUnit()), WeightSource.ESTIMATE);
        }
        // 6. 入库: 可靠/可参考的单重优先, 其次本仓均重, 再次任何单重。
        UnitWeightLookup.UnitWeightRef apw = ctx.apw();
        if (apw != null && apw.confident()) {
            return kept(WeightMath.times(q, apw.kgPerBaseUnit()), WeightSource.ESTIMATE);
        }
        if (averageKnown) {
            return kept(WeightMath.prorate(wb, q, qb), WeightSource.AVERAGE);
        }
        return apw == null ? Weighed.UNKNOWN : kept(WeightMath.times(q, apw.kgPerBaseUnit()), WeightSource.ESTIMATE);
    }

    /** 7. 算出 0 重量(数量大于 0)按未知处理; 只有来源切片的 0 原样留在流水上。 */
    private static Weighed kept(BigDecimal kg, WeightSource source) {
        if (kg == null || kg.signum() < 0) return Weighed.UNKNOWN;
        if (kg.signum() == 0 && source != WeightSource.SLICE) return Weighed.UNKNOWN;
        return new Weighed(WeightMath.round4(kg), source);
    }

    /** §2.4: 余额重量整值改写(同一条 upsert), 起算/尾差行同事务写入。 */
    private static WeightResolution balance(WeightContext ctx, BigDecimal q, boolean in,
                                            BigDecimal w, WeightSource source) {
        BigDecimal qb = ctx.balanceQty();
        BigDecimal newQ = in ? qb.add(q) : qb.subtract(q);
        List<AdjustmentDraft> before = new ArrayList<>();

        // 精确货品: 余额重量永远 = 数量 x 系数, 不写起算/尾差行。
        if (ctx.goodsMassFactor() != null) {
            BigDecimal exact = newQ.signum() > 0 ? positiveOrNull(WeightMath.times(newQ, ctx.goodsMassFactor()))
                    : newQ.signum() == 0 ? ZERO_KG : null;
            return new WeightResolution(w, source, before, exact, false);
        }

        // a. 起点: 零数量就是零重量(存的不是 0 先起算归零); 负数量(老库负库存)重量未知。
        BigDecimal stored = ctx.balanceWeight();
        BigDecimal base;
        boolean estimated;
        if (qb.signum() == 0) {
            base = ZERO_KG;
            estimated = false;
            if (ctx.balanceExists() && !WeightMath.isZero(stored)) {
                before.add(new AdjustmentDraft(AdjustmentDraft.ANCHOR, stored, ZERO_KG));
            }
        } else if (qb.signum() < 0) {
            base = null;
            estimated = false;
        } else {
            base = stored;
            estimated = ctx.balanceEstimated();
        }

        // b. 本笔重量未知: 数量归零则重量就是 0(流水行直接记 0), 否则余额重量变未知。
        if (w == null) {
            return new WeightResolution(null, null, before, newQ.signum() == 0 ? ZERO_KG : null, false);
        }

        // c. 本笔重量已知但原余额重量未知: 按单重(可靠/可参考)或本笔均重起算。
        if (base == null) {
            if (qb.signum() > 0) {
                UnitWeightLookup.UnitWeightRef apw = ctx.apw();
                BigDecimal anchor = apw != null && apw.confident()
                        ? WeightMath.times(qb, apw.kgPerBaseUnit())
                        : w.signum() > 0 ? WeightMath.prorate(w, qb, q) : null;
                if (!WeightMath.positive(anchor)) {
                    return reanchored(w, source, q, newQ, before);
                }
                before.add(new AdjustmentDraft(AdjustmentDraft.ANCHOR, stored, anchor));
                base = anchor;
                estimated = true;
            } else {
                return reanchored(w, source, q, newQ, before);
            }
        }

        // d. 两边都已知: 直接加减。数量归零却留下零头、或数量还有重量却减没了, 先写尾差行把余额纠正到
        //    「这笔流水正好落在目标上」的数, 再记流水。
        BigDecimal raw = in ? base.add(w) : base.subtract(w);
        if (newQ.signum() == 0) {
            if (raw.signum() != 0) {
                correct(before, base, ZERO_KG, in, w);
            }
            return new WeightResolution(w, source, before, ZERO_KG, false);
        }
        if (newQ.signum() < 0) {
            return new WeightResolution(w, source, before, null, false);
        }
        if (raw.signum() > 0) {
            // e. 入库带进来的是估算值, 余额也跟着变「≈」。
            boolean est = estimated || (in && source.estimated());
            return new WeightResolution(w, source, before, raw, est);
        }
        UnitWeightLookup.UnitWeightRef apw = ctx.apw();
        BigDecimal target = apw != null
                ? WeightMath.times(newQ, apw.kgPerBaseUnit())
                : w.signum() > 0 ? WeightMath.prorate(w, newQ, q) : null;
        if (WeightMath.positive(target)) {
            correct(before, base, target, in, w);
            return new WeightResolution(w, source, before, target, true);
        }
        return new WeightResolution(w, source, before, null, false);
    }

    /** 尾差行: 余额从 base 纠正到 target -/+ 本笔重量, 使本笔流水过账后正好是 target。 */
    private static void correct(List<AdjustmentDraft> before, BigDecimal base, BigDecimal target,
                                boolean in, BigDecimal w) {
        BigDecimal corrected = in ? target.subtract(w) : target.add(w);
        if (corrected.signum() >= 0 && corrected.compareTo(base) != 0) {
            before.add(new AdjustmentDraft(AdjustmentDraft.RESIDUAL, base, corrected));
        }
    }

    /**
     * 原余额重量无从起算(老库负数量, 或按本笔算不出正数): 不写调整行, 流水行直接给出按本笔均重重新起算的
     * 余额重量(估算), 数量归零则为 0。
     */
    private static WeightResolution reanchored(BigDecimal w, WeightSource source, BigDecimal q,
                                               BigDecimal newQ, List<AdjustmentDraft> before) {
        BigDecimal target = newQ.signum() > 0 ? (w.signum() > 0 ? positiveOrNull(WeightMath.prorate(w, newQ, q)) : null)
                : newQ.signum() == 0 ? ZERO_KG : null;
        return new WeightResolution(w, source, before, target, target != null && newQ.signum() > 0);
    }

    private static BigDecimal positiveOrNull(BigDecimal kg) {
        return WeightMath.positive(kg) ? kg : null;
    }

    // ===== 只改重量的调整 =====

    /**
     * 撤销一次盘点定重(§3.4): 盘点前重量已知时, 余额 = 当前 + (盘点前 - 盘点定的), 再套零数量规则;
     * 盘点前未知(或当前未知)时重量不动, 已知的标成估算。
     */
    public static CountReversal reverseCount(BigDecimal qty, BigDecimal currentKg, boolean currentEstimated,
                                             BigDecimal countBeforeKg, BigDecimal countAfterKg) {
        BigDecimal q = qty == null ? BigDecimal.ZERO : qty;
        if (q.signum() == 0) return new CountReversal(ZERO_KG, false);
        if (q.signum() < 0) return new CountReversal(null, false);
        if (countBeforeKg != null && countAfterKg != null && currentKg != null) {
            BigDecimal target = WeightMath.round4(currentKg.add(countBeforeKg.subtract(countAfterKg)));
            return target.signum() > 0 ? new CountReversal(target, currentEstimated) : new CountReversal(null, false);
        }
        return new CountReversal(currentKg, currentKg != null);
    }
}
