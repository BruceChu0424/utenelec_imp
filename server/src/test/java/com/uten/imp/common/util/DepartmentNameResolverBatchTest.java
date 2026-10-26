package com.uten.imp.common.util;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class DepartmentNameResolverBatchTest {
    @Test void emptyNullAndAllNullInputsNeverQuery() {
        EntityManager em = mock(EntityManager.class); var resolver = new DepartmentNameResolver(em);
        assertThat(resolver.namesOf(null)).isEmpty(); assertThat(resolver.namesOf(List.of())).isEmpty();
        assertThat(resolver.namesOf(Arrays.asList(null, null))).isEmpty(); verifyNoInteractions(em);
    }

    @Test void distinctNonNullIdsUseBoundedReadsAndMissingNamesNeverBecomeLabels() {
        EntityManager em = mock(EntityManager.class); var resolver = new DepartmentNameResolver(em);
        List<UUID> unique = java.util.stream.IntStream.range(0, 257).mapToObj(i -> UUID.randomUUID()).toList();
        List<UUID> ids = new ArrayList<>(unique); ids.add(unique.getFirst()); ids.add(null);
        List<Integer> sizes = new ArrayList<>(); UUID missing = unique.getFirst();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            assertThat(call.<String>getArgument(0)).contains("COALESCE(is_deleted, false) = false");
            Query query = mock(Query.class, RETURNS_SELF); AtomicReference<List<UUID>> batch = new AtomicReference<>();
            when(query.setParameter(eq("ids"), any())).thenAnswer(binding -> {
                List<UUID> values = binding.getArgument(1); batch.set(values); sizes.add(values.size()); return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> batch.get().stream().filter(id -> !id.equals(missing))
                    .map(id -> new Object[]{id, "部门 " + id}).toList());
            return query;
        });
        var result = resolver.namesOf(ids);
        assertThat(sizes).containsExactly(256, 1); assertThat(result).hasSize(256).doesNotContainKey(missing);
        assertThat(result.get(unique.get(1))).startsWith("部门 ");
        assertThatThrownBy(() -> result.put(UUID.randomUUID(), "改写")).isInstanceOf(UnsupportedOperationException.class);
    }
}
