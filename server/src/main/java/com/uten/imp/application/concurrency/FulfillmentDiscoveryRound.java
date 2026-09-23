package com.uten.imp.application.concurrency;

import com.uten.imp.common.util.CanonicalFingerprint;

import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.function.Supplier;

/**
 * 一轮只读发现(一次预锁的预读, 或锁后的那一次版本复核)内的去重(ADR-107)。
 *
 * <p>同一轮里各个子足迹(订货单、来源明细、唤醒目标、BOM 可达集……)按「方法 + 参数」只读一次;
 * 物料分析的展开(来源、供给动作、预留、结构)推迟到本轮末尾, 对全部涉及的分析并集只展开一次——
 * 各查询都是 {@code IN (:ids)} 的并集语义, 并集展开得到的锁集合与逐个展开的并集完全相同。
 * 两轮之间什么都不共享: 锁后复核必须重新读库。</p>
 *
 * <p>轮次只存在于发起它的线程的一次同步调用里, 不跨事务、不跨线程。</p>
 */
public final class FulfillmentDiscoveryRound {
    private static final ThreadLocal<FulfillmentDiscoveryRound> CURRENT = new ThreadLocal<>();

    private final Map<List<Object>, Object> memo = new HashMap<>();
    private final Set<UUID> deferredAnalyses = new LinkedHashSet<>();
    private Function<Set<UUID>, FulfillmentMutationLockPlan> analysisExpander;
    private boolean finishing;

    private FulfillmentDiscoveryRound() { }

    /** 在一轮内执行发现; 已处于某一轮时直接并入该轮。 */
    static FulfillmentMutationLockPlan discover(Supplier<FulfillmentMutationLockPlan> discovery) {
        if (CURRENT.get() != null) return Objects.requireNonNull(discovery.get());
        FulfillmentDiscoveryRound round = new FulfillmentDiscoveryRound();
        CURRENT.set(round);
        try {
            return round.finish(Objects.requireNonNull(discovery.get()));
        } finally {
            CURRENT.remove();
        }
    }

    /**
     * 本轮内按 (kind, args) 缓存一次读取; 轮外(单独的覆盖检查、测试直调)照常每次读取。
     * 缓存的值必须是不可变的, 调用方不得修改。
     */
    @SuppressWarnings("unchecked")
    public static <T> T memo(String kind, Object args, Supplier<T> loader) {
        FulfillmentDiscoveryRound round = CURRENT.get();
        if (round == null) return loader.get();
        List<Object> key = List.of(kind, Objects.requireNonNullElse(args, List.of()));
        if (round.memo.containsKey(key)) return (T) round.memo.get(key);
        T value = loader.get();
        round.memo.put(key, value);
        return value;
    }

    /**
     * 把分析展开推迟到本轮末尾统一做一次。返回 false 表示当前不在可推迟的轮次里
     * (轮外调用, 或本轮已在收尾展开), 调用方须当场展开。
     *
     * <p>展开器返回的计划只含来源、库存维度和主仓, 不含分析 id 本身——哪些分析进锁集合
     * 仍由各足迹自己的返回值决定。</p>
     */
    public static boolean deferAnalysisExpansion(Collection<UUID> analysisIds,
            Function<Set<UUID>, FulfillmentMutationLockPlan> expander) {
        FulfillmentDiscoveryRound round = CURRENT.get();
        if (round == null || round.finishing) return false;
        // 只有生产足迹服务会推迟展开; 同一轮里它每次传来的方法引用等价, 保留第一个即可。
        if (round.analysisExpander == null) round.analysisExpander = expander;
        analysisIds.stream().filter(Objects::nonNull).forEach(round.deferredAnalyses::add);
        return true;
    }

    private FulfillmentMutationLockPlan finish(FulfillmentMutationLockPlan plan) {
        if (analysisExpander == null || deferredAnalyses.isEmpty()) return plan;
        finishing = true;
        FulfillmentMutationLockPlan expansion = Objects.requireNonNull(
                analysisExpander.apply(Set.copyOf(deferredAnalyses)));
        Set<FulfillmentMutationLockPlan.CommercialSource> sources = new HashSet<>(plan.commercialSources());
        sources.addAll(expansion.commercialSources());
        Set<FulfillmentMutationLockPlan.InventoryDimension> inventory = new HashSet<>(plan.inventoryDimensions());
        inventory.addAll(expansion.inventoryDimensions());
        Set<UUID> warehouses = new HashSet<>(plan.mainWarehouseIds());
        warehouses.addAll(expansion.mainWarehouseIds());
        return new FulfillmentMutationLockPlan(sources, inventory, warehouses, plan.analysisIds(),
                CanonicalFingerprint.sha256(List.of(plan.fingerprint(), "analysis-expansion:" + expansion.fingerprint())));
    }
}
