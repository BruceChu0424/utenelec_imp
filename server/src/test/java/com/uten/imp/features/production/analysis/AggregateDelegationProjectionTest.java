package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * {@link AggregateDelegationProjection} 纯函数单测：任意深度的份额折算、BOM 取整
 * 规则、嵌套共享批次的目标解析、成员行份额不被 BOM 折算改写。
 *
 * <p>树形(合成)：两棵产品树 P1/P2，root → 共享件 A → 中层 B → 叶子 C；
 * 共享批次锚点树 A' → B' → C'。成员 = A@P1(2) 与 A@P2(3)。</p>
 */
class AggregateDelegationProjectionTest {

    private static final UUID GOODS_ROOT = UUID.randomUUID();
    private static final UUID GOODS_A = UUID.randomUUID();
    private static final UUID GOODS_B = UUID.randomUUID();
    private static final UUID GOODS_C = UUID.randomUUID();

    private final List<AggregateDelegationProjection.Node> nodes = new ArrayList<>();

    private AggregateDelegationProjection.Node node(
            UUID analysisLine, String key, String parentKey, UUID goods,
            String bomQty, UUID bomItemId, String basis, String basisOutput,
            boolean allowPartial, boolean rootSupply) {
        var value = new AggregateDelegationProjection.Node(
                UUID.randomUUID(), analysisLine, key, parentKey, goods, bomItemId,
                new BigDecimal(bomQty), basis,
                basisOutput == null ? null : new BigDecimal(basisOutput),
                allowPartial, rootSupply);
        nodes.add(value);
        return value;
    }

    /** P1/P2 两棵 root→A→B→C(全 PER_UNIT，B 用量 1、C 用量 2) + 锚点树 A'→B'→C'。 */
    private record World(
            UUID line1, UUID line2, UUID anchorLine,
            AggregateDelegationProjection.Node a1, AggregateDelegationProjection.Node b1,
            AggregateDelegationProjection.Node c1,
            AggregateDelegationProjection.Node a2, AggregateDelegationProjection.Node b2,
            AggregateDelegationProjection.Node c2,
            AggregateDelegationProjection.Node anchorRoot,
            AggregateDelegationProjection.Node bAnchor,
            AggregateDelegationProjection.Node cAnchor) {
    }

    private World perUnitWorld() {
        UUID line1 = UUID.randomUUID(), line2 = UUID.randomUUID(), anchor = UUID.randomUUID();
        node(line1, "root", null, GOODS_ROOT, "1", null, "PER_UNIT", "1", true, true);
        var a1 = node(line1, "a", "root", GOODS_A, "1", edgeA(), "PER_UNIT", "1", true, false);
        var b1 = node(line1, "b", "a", GOODS_B, "1", edgeB(), "PER_UNIT", "1", true, false);
        var c1 = node(line1, "c", "b", GOODS_C, "2", edgeC(), "PER_UNIT", "1", true, false);
        node(line2, "root", null, GOODS_ROOT, "1", null, "PER_UNIT", "1", true, true);
        var a2 = node(line2, "a", "root", GOODS_A, "1", edgeA(), "PER_UNIT", "1", true, false);
        var b2 = node(line2, "b", "a", GOODS_B, "1", edgeB(), "PER_UNIT", "1", true, false);
        var c2 = node(line2, "c", "b", GOODS_C, "2", edgeC(), "PER_UNIT", "1", true, false);
        var anchorRoot = node(anchor, "root", null, GOODS_A, "1", null, "PER_UNIT", "1", true, true);
        var bAnchor = node(anchor, "b", "root", GOODS_B, "1", edgeB(), "PER_UNIT", "1", true, false);
        var cAnchor = node(anchor, "c", "b", GOODS_C, "2", edgeC(), "PER_UNIT", "1", true, false);
        return new World(line1, line2, anchor, a1, b1, c1, a2, b2, c2,
                anchorRoot, bAnchor, cAnchor);
    }

    // BOM 边按「货品+层级」共用同一 UUID，模拟同一 BOM 边在原树与锚点树上同 id。
    private static UUID edgeA() { return EDGE_A; }
    private static UUID edgeB() { return EDGE_B; }
    private static UUID edgeC() { return EDGE_C; }
    private static final UUID EDGE_A = UUID.randomUUID();
    private static final UUID EDGE_B = UUID.randomUUID();
    private static final UUID EDGE_C = UUID.randomUUID();

    private static AggregateDelegationProjection.Member member(
            AggregateDelegationProjection.Node source, UUID anchorLine, String qty) {
        return new AggregateDelegationProjection.Member(
                source.materialId(), anchorLine, new BigDecimal(qty));
    }

    @Test
    void sharesAndTargetsResolveAtEveryDepth() {
        World world = perUnitWorld();
        Map<UUID, AggregateDelegationProjection.Delegation> result = AggregateDelegationProjection.project(
                nodes,
                List.of(member(world.a1(), world.anchorLine(), "2"),
                        member(world.a2(), world.anchorLine(), "3")),
                // 成员直接子层由别名绑定(写入服务 installAliases 落的行)。
                List.of(new AggregateDelegationProjection.Alias(
                                world.b1().materialId(), world.bAnchor().materialId(), new BigDecimal("2")),
                        new AggregateDelegationProjection.Alias(
                                world.b2().materialId(), world.bAnchor().materialId(), new BigDecimal("3"))));

        // 成员行：份额 = 转交量本身(不被 BOM 折算改写)，目标 = 锚点根行。
        assertThat(result.get(world.a1().materialId()).qty()).isEqualByComparingTo("2");
        assertThat(result.get(world.a1().materialId()).targetMaterialLineId())
                .isNull();

        // 直接子层(别名行)：份额 = 别名量，目标 = 别名目标行。
        assertThat(result.get(world.b1().materialId()).qty()).isEqualByComparingTo("2");
        assertThat(result.get(world.b1().materialId()).targetMaterialLineId())
                .isEqualTo(world.bAnchor().materialId());

        // 孙层(无别名)：按 BOM 数学自成员份额折算(2 × 1 × 2)，目标在锚点树上并行下行。
        assertThat(result.get(world.c1().materialId()).qty()).isEqualByComparingTo("4");
        assertThat(result.get(world.c1().materialId()).targetMaterialLineId())
                .isEqualTo(world.cAnchor().materialId());
        assertThat(result.get(world.c2().materialId()).qty()).isEqualByComparingTo("6");

        // 锚点树自己的行不在投影里——它们承载真实需求，不锁份额。
        assertThat(result).doesNotContainKey(world.anchorRoot().materialId());
        assertThat(result).doesNotContainKey(world.bAnchor().materialId());
    }

    @Test
    void fixedBatchRoundingAppliesLevelByLevel() {
        UUID line = UUID.randomUUID(), anchor = UUID.randomUUID();
        node(line, "root", null, GOODS_ROOT, "1", null, "PER_UNIT", "1", true, true);
        var parent = node(line, "a", "root", GOODS_A, "1", EDGE_A, "PER_UNIT", "1", true, false);
        // 固定批次：每 5 件父件产出耗 1 批(1 件)，且不允许拆包——向上取整。
        var leaf = node(line, "leaf", "a", GOODS_C, "1", UUID.randomUUID(),
                "FIXED_BATCH", "5", false, false);
        node(anchor, "root", null, GOODS_A, "1", null, "PER_UNIT", "1", true, true);
        node(anchor, "leaf", "root", GOODS_C, "1", leaf.bomItemId(), "FIXED_BATCH", "5", false, false);

        var target=nodes.getLast();
        Map<UUID, AggregateDelegationProjection.Delegation> result = AggregateDelegationProjection.project(
                nodes, List.of(member(parent, anchor, "7")), List.of(
                    new AggregateDelegationProjection.Alias(leaf.materialId(),target.materialId(),new BigDecimal("2"))));

        // 7 件父件 → ceil(7/5)=2 批 → 2 件叶子；不是 7/5=1.4 也不是 7。
        assertThat(result.get(leaf.materialId()).qty()).isEqualByComparingTo("2");
    }

    @Test
    void nestedSharedBatchesResolveToTheFinalOrderedRow() {
        World world = perUnitWorld();
        UUID anchor2 = UUID.randomUUID();
        // 第二层共享批次：锚点树上的 B' 又整体转给了更深的批次(目标 = 其根行)。
        var secondRoot = node(anchor2, "root", null, GOODS_B, "1", null, "PER_UNIT", "1", true, true);
        var secondLeaf = node(anchor2, "c", "root", GOODS_C, "2", EDGE_C, "PER_UNIT", "1", true, false);

        Map<UUID, AggregateDelegationProjection.Delegation> result = AggregateDelegationProjection.project(
                nodes,
                List.of(member(world.a1(), world.anchorLine(), "2"),
                        member(world.bAnchor(), anchor2, "2")),
                List.of(new AggregateDelegationProjection.Alias(
                                world.b1().materialId(), world.bAnchor().materialId(), new BigDecimal("2")),
                        // 第二层批次的 installAliases 同样绑定成员(B')的子层。
                        new AggregateDelegationProjection.Alias(
                                world.cAnchor().materialId(), secondLeaf.materialId(), new BigDecimal("4"))));

        // 原树 B 行的直接目标是 B'，但 B' 自己转入了第二层批次——要一路解析到
        // 最终承载下单引用的根行，进度列才有真实阶段可报。
        assertThat(result.get(world.b1().materialId()).targetMaterialLineId())
                .isEqualTo(world.bAnchor().materialId());
        // 原树 C 行跟着解析到第二层批次树上的 C 行。
        assertThat(result.get(world.c1().materialId()).targetMaterialLineId())
                .isEqualTo(secondLeaf.materialId());
        // 份额不受解析影响，仍是本行自己的 BOM 折算值。
        assertThat(result.get(world.c1().materialId()).qty()).isEqualByComparingTo("4");
    }

    @Test void equalGoodsWithDifferentBomEdgesCannotBecomeAWriteTarget() {
        World world=perUnitWorld();
        var wrong=node(world.anchorLine(),"other","b",GOODS_C,"2",UUID.randomUUID(),"PER_UNIT","1",true,false);
        nodes.remove(world.cAnchor());
        var result=AggregateDelegationProjection.project(nodes,List.of(),List.of(
                new AggregateDelegationProjection.Alias(world.b1().materialId(),world.bAnchor().materialId(),new BigDecimal("2"))));
        assertThat(result).doesNotContainKey(world.c1().materialId());
        assertThat(result.values()).noneMatch(value->value.targetMaterialLineIds().contains(wrong.materialId()));
    }

    @Test void aMemberWithoutSyntheticRootNeverUsesAnArbitraryComponentAsItsIdentity() {
        World world=perUnitWorld();nodes.remove(world.anchorRoot());
        var result=AggregateDelegationProjection.project(nodes,List.of(member(world.a1(),world.anchorLine(),"2")),List.of());
        assertThat(result.get(world.a1().materialId()).qty()).isEqualByComparingTo("2");
        assertThat(result.get(world.a1().materialId()).targetMaterialLineIds()).isEmpty();
        assertThat(result).doesNotContainKey(world.b1().materialId());
    }

    @Test void multipleBatchesAccumulateAndRetainEveryExactTarget() {
        World world=perUnitWorld();UUID second=UUID.randomUUID();
        var secondTarget=node(second,"b",null,GOODS_B,"1",EDGE_B,"PER_UNIT","1",true,false);
        var result=AggregateDelegationProjection.project(nodes,List.of(),List.of(
                new AggregateDelegationProjection.Alias(world.b1().materialId(),world.bAnchor().materialId(),new BigDecimal("2")),
                new AggregateDelegationProjection.Alias(world.b1().materialId(),secondTarget.materialId(),new BigDecimal("3"))));
        assertThat(result.get(world.b1().materialId()).qty()).isEqualByComparingTo("5");
        assertThat(result.get(world.b1().materialId()).targetMaterialLineIds()).containsExactlyInAnyOrder(world.bAnchor().materialId(),secondTarget.materialId());
        assertThat(result.get(world.b1().materialId()).targetMaterialLineId()).isNull();
    }

    @Test void sharedWholePackagesRoundTheBatchOnceAndConserveTheSourceShares() {
        World world=perUnitWorld();nodes.remove(world.c1());nodes.remove(world.c2());nodes.remove(world.cAnchor());
        var c1=node(world.line1(),"c","b",GOODS_C,"1",EDGE_C,"PER_PACKAGE","5",false,false);
        var c2=node(world.line2(),"c","b",GOODS_C,"1",EDGE_C,"PER_PACKAGE","5",false,false);
        var canonical=node(world.anchorLine(),"c","b",GOODS_C,"1",EDGE_C,"PER_PACKAGE","5",false,false);
        var result=AggregateDelegationProjection.project(nodes,List.of(),List.of(
                new AggregateDelegationProjection.Alias(world.b1().materialId(),world.bAnchor().materialId(),new BigDecimal("2")),
                new AggregateDelegationProjection.Alias(world.b2().materialId(),world.bAnchor().materialId(),new BigDecimal("3"))));
        assertThat(result.get(c1.materialId()).qty().add(result.get(c2.materialId()).qty())).isEqualByComparingTo("1");
        assertThat(result.get(c1.materialId()).targetMaterialLineId()).isEqualTo(canonical.materialId());
    }

    @Test void zeroAliasesKeepTheExactAppendIdentityWithoutInventingDemand() {
        World world=perUnitWorld();
        var result=AggregateDelegationProjection.project(nodes,List.of(),List.of(
                new AggregateDelegationProjection.Alias(world.b1().materialId(),world.bAnchor().materialId(),BigDecimal.ZERO)));
        assertThat(result.get(world.b1().materialId()).qty()).isZero();
        assertThat(result.get(world.c1().materialId()).targetMaterialLineId()).isEqualTo(world.cAnchor().materialId());
    }
}
