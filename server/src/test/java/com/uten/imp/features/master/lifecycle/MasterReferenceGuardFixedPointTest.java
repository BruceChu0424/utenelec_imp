package com.uten.imp.features.master.lifecycle;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Predicate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 同批删除的不动点(ADR-111 评审 blocker 回归)：样例截断到 10 条之后不能再参与「有没有变化」
 * 的判定，否则一个组件有 10 个以上父件时循环永不停止，还攥着整批货品的 FOR UPDATE 锁。
 *
 * <p>引用查询的结果行用替身直接给出(形状同真库：目标、种类、引用方、标签、归属人、可见范围、总数)，
 * 只测 Java 侧的收敛与合计；SQL 本身由 MasterDataIntegrityEndToEndTest 在真库上跑。
 */
class MasterReferenceGuardFixedPointTest {

    private static final Duration LIMIT = Duration.ofSeconds(5);

    @Test
    void tenExternalParentsPlusOneBlockedInternalParentConvergesAndCountsBoth() {
        UUID parent = UUID.randomUUID();
        UUID component = UUID.randomUUID();
        List<Object[]> rows = new ArrayList<>();
        rows.add(row(parent, "SALES_ORDER", UUID.randomUUID().toString(), "SO-0001", 1));
        // SQL 只回前 10 个外部父件样例，总数 30。
        for (int i = 0; i < 10; i++) {
            rows.add(row(component, "BOM_PARENT", UUID.randomUUID().toString(), "EXT-" + i, 30));
        }
        rows.add(row(component, "BOM_INTERNAL", parent.toString(), "P-001 同批父件", 1));

        Map<UUID, List<MasterReferenceGuard.Blocker>> result = assertTimeoutPreemptively(LIMIT,
                () -> guard(rows).goodsBlockers(List.of(parent, component)));

        MasterReferenceGuard.Blocker bom = only(result.get(component), MasterReferenceGuard.RefKind.BOM_PARENT);
        assertThat(bom.total()).isEqualTo(31);
        assertThat(bom.samples()).hasSize(MasterReferenceGuard.SAMPLE_LIMIT);
        assertThat(result.get(parent)).extracting(MasterReferenceGuard.Blocker::kind)
                .containsExactly(MasterReferenceGuard.RefKind.SALES_ORDER);
    }

    @Test
    void elevenBlockedInternalParentsConvergeWithTheExactTotal() {
        UUID component = UUID.randomUUID();
        List<UUID> ids = new ArrayList<>();
        List<Object[]> rows = new ArrayList<>();
        for (int i = 0; i < 11; i++) {
            UUID parent = UUID.randomUUID();
            ids.add(parent);
            rows.add(row(parent, "STOCK", UUID.randomUUID().toString(), "成品仓 5", 1));
            rows.add(row(component, "BOM_INTERNAL", parent.toString(), String.format("P-%02d", i), 1));
        }
        ids.add(component);

        Map<UUID, List<MasterReferenceGuard.Blocker>> result = assertTimeoutPreemptively(LIMIT,
                () -> guard(rows).goodsBlockers(ids));

        MasterReferenceGuard.Blocker bom = only(result.get(component), MasterReferenceGuard.RefKind.BOM_PARENT);
        assertThat(bom.total()).isEqualTo(11);
        assertThat(bom.samples()).hasSize(MasterReferenceGuard.SAMPLE_LIMIT).startsWith("P-00", "P-01");
        assertThat(MasterReferenceGuard.reason(bom)).contains("等共 11 处");
    }

    @Test
    void blockingCascadesDownAChainOfSameBatchParents() {
        UUID top = UUID.randomUUID();
        UUID middle = UUID.randomUUID();
        UUID leaf = UUID.randomUUID();
        List<Object[]> rows = List.of(
                row(top, "SALES_ORDER", UUID.randomUUID().toString(), "SO-9", 1),
                // 行序故意倒过来：leaf 先出现，第一轮看不到 middle 已被挡住，要靠下一轮。
                row(leaf, "BOM_INTERNAL", middle.toString(), "M-1 中间件", 1),
                row(middle, "BOM_INTERNAL", top.toString(), "T-1 顶层件", 1));

        Map<UUID, List<MasterReferenceGuard.Blocker>> result = assertTimeoutPreemptively(LIMIT,
                () -> guard(rows).goodsBlockers(List.of(top, middle, leaf)));

        assertThat(result).containsOnlyKeys(top, middle, leaf);
        assertThat(only(result.get(middle), MasterReferenceGuard.RefKind.BOM_PARENT).samples())
                .containsExactly("T-1 顶层件");
        assertThat(only(result.get(leaf), MasterReferenceGuard.RefKind.BOM_PARENT).samples())
                .containsExactly("M-1 中间件");
    }

    @Test
    void parentAndComponentDeletedTogetherAreBothReleasedWhenNothingElseBlocks() {
        UUID parent = UUID.randomUUID();
        UUID component = UUID.randomUUID();
        List<Object[]> rows = List.<Object[]>of(row(component, "BOM_INTERNAL", parent.toString(), "P-1", 1));

        Map<UUID, List<MasterReferenceGuard.Blocker>> result = assertTimeoutPreemptively(LIMIT,
                () -> guard(rows).goodsBlockers(List.of(parent, component)));

        assertThat(result).isEmpty();
    }

    @Test
    void labelsTheCallerCannotSeeAreCountedButNotShown() {
        UUID component = UUID.randomUUID();
        UUID hiddenOwner = UUID.randomUUID();
        List<Object[]> rows = List.of(
                new Object[]{component, "BOM_PARENT", UUID.randomUUID().toString(), "别人的货品", hiddenOwner,
                        "goods", 2L},
                new Object[]{component, "BOM_PARENT", UUID.randomUUID().toString(), "我的货品", null,
                        "goods", 2L},
                new Object[]{component, "SALES_ORDER", UUID.randomUUID().toString(), "SO-别人", hiddenOwner,
                        "sales", 1L});
        MasterObjectAccess access = mock(MasterObjectAccess.class);
        Predicate<UUID> notHidden = owner -> !hiddenOwner.equals(owner);
        when(access.readableLabelOwner(anyString())).thenReturn(notHidden);

        Map<UUID, List<MasterReferenceGuard.Blocker>> result =
                new MasterReferenceGuard(entityManager(rows), access).goodsBlockers(List.of(component));

        String text = MasterReferenceGuard.describe(MasterEntityKind.GOODS, "C-1", result.get(component));
        assertThat(text).contains("我的货品").contains("等共 2 处")
                .doesNotContain("别人的货品").doesNotContain("SO-别人")
                .contains("还有未结案的销售订单：共 1 处(你没有权限查看明细");
    }

    // ---- helpers -------------------------------------------------------------------

    private static Object[] row(UUID target, String code, String ref, String label, long total) {
        return new Object[]{target, code, ref, label, null, "public", total};
    }

    private static MasterReferenceGuard guard(List<Object[]> rows) {
        MasterObjectAccess access = mock(MasterObjectAccess.class);
        when(access.readableLabelOwner(anyString())).thenReturn(owner -> true);
        return new MasterReferenceGuard(entityManager(rows), access);
    }

    private static EntityManager entityManager(List<Object[]> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.getResultList()).thenReturn(new ArrayList<Object>(rows));
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        return em;
    }

    private static MasterReferenceGuard.Blocker only(List<MasterReferenceGuard.Blocker> blockers,
                                                     MasterReferenceGuard.RefKind kind) {
        assertThat(blockers).isNotNull();
        return blockers.stream().filter(blocker -> blocker.kind() == kind).findFirst()
                .orElseThrow(() -> new AssertionError("missing " + kind + " in " + blockers));
    }
}
