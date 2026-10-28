package com.uten.imp.features.profilechange;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProfileChangeBatchQueryTest {
    @Test void searchesCountAndSortWholeBatchesBeforeApplyingThePageWindow() {
        EntityManager em = mock(EntityManager.class);
        Query count = mock(Query.class, RETURNS_SELF);
        Query rows = mock(Query.class, RETURNS_SELF);
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String statement = call.getArgument(0);
            sql.add(statement);
            return statement.startsWith("SELECT COUNT(*)") ? count : rows;
        });
        when(count.getSingleResult()).thenReturn(3L);
        UUID batchId = UUID.randomUUID(), mine = UUID.randomUUID();
        when(rows.getResultList()).thenReturn(List.of(batchId));

        var page = new ProfileChangeBatchQuery(em).page("pending", mine, null, null,
                2, 1, Map.of("itemCount", ">=2", "fields", "测试字段"), "itemCount", "desc");

        assertThat(page.getTotalElements()).isEqualTo(3);
        assertThat(page.getContent()).containsExactly(batchId);
        assertThat(sql).hasSize(2).allSatisfy(statement -> {
            assertThat(statement).contains("GROUP BY p.batch_id", "COUNT(*) AS item_count", ") batch WHERE ", "batch.item_count >= :");
            assertThat(statement.indexOf("GROUP BY p.batch_id")).isLessThan(statement.indexOf(") batch WHERE "));
        });
        assertThat(sql.get(1)).contains("ORDER BY batch.item_count DESC,batch.batch_id DESC");
        verify(count).setParameter("submittedBy", mine);
        verify(rows).setParameter("submittedBy", mine);
        verify(rows).setFirstResult(1);
        verify(rows).setMaxResults(1);
    }
}
