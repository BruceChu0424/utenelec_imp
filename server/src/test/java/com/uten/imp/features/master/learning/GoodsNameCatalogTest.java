package com.uten.imp.features.master.learning;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** 中文品名召回索引: 结尾一致 → 二元组相似 → 包含 的优先级, 去括号限定语, 签名变化才重建。 */
class GoodsNameCatalogTest {

    private final UUID nigeria = UUID.fromString("00000000-0000-0000-0000-000000000001");
    private final UUID bracket = UUID.fromString("00000000-0000-0000-0000-000000000002");
    private final UUID fuzzy = UUID.fromString("00000000-0000-0000-0000-000000000003");
    private final UUID contains = UUID.fromString("00000000-0000-0000-0000-000000000004");
    private final UUID unrelated = UUID.fromString("00000000-0000-0000-0000-000000000005");

    private final List<Object[]> rows = new ArrayList<>(List.of(
            new Object[]{nigeria, "尼日利亚6M 一开13A带A+C双USB"},
            new Object[]{bracket, "Z9一开13A带A+C双USB\uFF08新款\uFF09"},
            new Object[]{fuzzy, "Z9一开13A带双USB插座"},
            // 名称很长: 只「包含」文件品名, 二元组相似度低于召回下限。
            new Object[]{contains, "配件包一开13A带A+C双USB专用面板底座与安装螺丝组合套装含说明书及包装盒外箱标签合格证保修卡以及备用零件清单和检验记录表格"},
            new Object[]{unrelated, "V5多功能保护门"}));
    private final AtomicInteger loads = new AtomicInteger();
    private Object[] signature = new Object[]{5L, 10L, "t1"};

    @Test
    void ranksSuffixMatchesBeforeFuzzyAndPlainContainment() {
        GoodsNameCatalog catalog = new GoodsNameCatalog(entityManager());

        List<UUID> hits = catalog.search(List.of("一开13A带A+C 双USB"), 10);

        assertThat(hits).containsSubsequence(nigeria, bracket, fuzzy, contains);
        assertThat(hits.indexOf(contains)).as("只是包含的排在二元组相似之后").isGreaterThan(hits.indexOf(fuzzy));
        assertThat(hits).doesNotContain(unrelated);
        assertThat(catalog.search(List.of("一开13A带A+C 双USB"), 2)).containsExactly(nigeria, bracket);
    }

    @Test
    void rebuildsOnlyWhenTheGoodsSignatureChanges() {
        GoodsNameCatalog catalog = new GoodsNameCatalog(entityManager());
        catalog.search(List.of("保护门"), 5);
        catalog.search(List.of("保护门"), 5);
        assertThat(loads.get()).isEqualTo(1);

        UUID added = UUID.randomUUID();
        rows.add(new Object[]{added, "V7保护门"});
        signature = new Object[]{6L, 11L, "t2"};
        assertThat(catalog.search(List.of("保护门"), 5)).contains(added, unrelated);
        assertThat(loads.get()).isEqualTo(2);
    }

    @Test
    void blankOrTinyInputRecallsNothing() {
        GoodsNameCatalog catalog = new GoodsNameCatalog(entityManager());
        assertThat(catalog.search(List.of(" ", ""), 10)).isEmpty();
        assertThat(catalog.search(List.of("门"), 10)).as("单字既不做包含也没有二元组").isEmpty();
        assertThat(catalog.search(List.of("保护门"), 0)).isEmpty();
    }

    private EntityManager entityManager() {
        EntityManager em = mock(EntityManager.class);
        Query signatureQuery = mock(Query.class);
        when(signatureQuery.getSingleResult()).thenAnswer(invocation -> signature);
        Query loadQuery = mock(Query.class);
        when(loadQuery.getResultList()).thenAnswer(invocation -> {
            loads.incrementAndGet();
            return List.copyOf(rows);
        });
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            return sql.contains("SELECT id, name") ? loadQuery : signatureQuery;
        });
        return em;
    }
}
