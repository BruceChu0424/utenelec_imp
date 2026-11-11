package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.*;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.*;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterExportSelectionTest {
    // Concrete test interfaces retain generic class-token types for Mockito;
    // the production criteria/repository contracts still receive Object rows.
    interface ObjectRoot extends Root<Object> { }
    interface ObjectPath extends Path<Object> { }
    interface ObjectRepository extends JpaSpecificationExecutor<Object> { }
    @Test void absentRawSelectionDoesNotAddAnUnknownFieldToNativeCreationProof() throws Exception {
        var projection = new TableColumnProjection("master.unit", "master_unit", List.of(
                new TableColumnProjection.Column("code", "Code", 120d, "text", null)));
        assertThat(new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(projection)).doesNotContain("rowSelection");
    }
    @Test void repositoryReceivesOriginalPredicateAndSelectedIdentityIntersection() {
        UUID id = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        JpaSpecificationExecutor<Object> repo = mock(ObjectRepository.class);
        Root<Object> root = mock(ObjectRoot.class); CriteriaQuery<?> query = mock(CriteriaQuery.class);
        CriteriaBuilder cb = mock(CriteriaBuilder.class); Path<Object> identity = mock(ObjectPath.class);
        Predicate authorised = mock(Predicate.class), selected = mock(Predicate.class), intersection = mock(Predicate.class);
        var originalVisited = new java.util.concurrent.atomic.AtomicBoolean();
        Specification<Object> original = (r, q, b) -> { originalVisited.set(true); return authorised; };
        when(root.get("id")).thenReturn(identity); when(identity.in(Set.of(id))).thenReturn(selected);
        when(cb.and(authorised, selected)).thenReturn(intersection);
        Pageable page = PageRequest.of(0, 100);
        when(repo.findAll(org.mockito.ArgumentMatchers.<Specification<Object>>any(), eq(page))).thenAnswer(call -> {
            Specification<Object> spec = call.getArgument(0);
            spec.toPredicate(root, query, cb);
            assertThat(originalVisited).isTrue();
            verify(identity).in(Set.of(id));
            return new PageImpl<>(List.of(new Object()), page, 1);
        });
        try (var ignored = MasterExportSelection.open(List.of(id))) {
            assertThat(MasterExportSource.page(repo, em, Object.class, original, page).getTotalElements()).isEqualTo(1);
            MasterExportSelection.requireComplete(1);
            assertThatThrownBy(() -> MasterExportSelection.requireComplete(0)).isInstanceOf(ApiException.class)
                    .hasMessageContaining("本次未生成文件");
        }
        assertThat(MasterExportSelection.current()).isNull();
    }
    @Test void staleSelectionFailsBeforeMappingAndNeverFallsBackToAll() {
        var em = mock(EntityManager.class);
        try (var ignored = MasterExportSelection.open(List.of(UUID.randomUUID(), UUID.randomUUID()))) {
            assertThatThrownBy(() -> MasterExportSource.exportEntities(em, List.of(),
                    (page, size) -> new com.uten.imp.common.web.PageResponse<>(List.of("one"), page, size, 1, 1),
                    item -> { throw new AssertionError("must reject before mapping"); }))
                    .isInstanceOf(ApiException.class).hasMessageContaining("当前筛选及权限范围");
        }
        assertThat(MasterExportSelection.current()).isNull();
    }
    @Test void failedNestedScopeRestoresItsOriginalSelection() {
        UUID id = UUID.randomUUID();
        try (var original = MasterExportSelection.open(List.of(id))) {
            assertThatThrownBy(() -> { try (var ignored = MasterExportSelection.open(null)) {
                assertThat(MasterExportSelection.current()).isNull(); throw new IllegalStateException();
            }}).isInstanceOf(IllegalStateException.class);
            assertThat(MasterExportSelection.current()).containsExactly(id);
        }
        assertThat(MasterExportSelection.current()).isNull();
    }
    @Test void largeSelectionUsesOneTypedArrayInsteadOfExpandingScalarParameters(){
        List<UUID> ids=java.util.stream.IntStream.rangeClosed(1,50001).mapToObj(i->new UUID(1,i)).toList();
        Root<Object> root=mock(ObjectRoot.class);CriteriaQuery<?> query=mock(CriteriaQuery.class);
        var cb=mock(org.hibernate.query.criteria.HibernateCriteriaBuilder.class);
        Path<Object> identity=mock(ObjectPath.class);when(root.get("id")).thenReturn(identity);
        // b538aba56 2026-11-10: membership renders as id = ANY(constant uuid[]) so
        // PostgreSQL hashes the array at plan time; array_contains (@>) re-scanned
        // the selected array per candidate row. The pinned invariant is unchanged:
        // one typed array bind, no scalar expansion, identity still narrowed.
        var bound=mock(org.hibernate.query.criteria.JpaExpression.class);
        when(cb.value(any(UUID[].class))).thenAnswer(call->bound);
        try(var ignored=MasterExportSelection.open(ids)){
            MasterExportSelection.<Object>intersect(null).toPredicate(root,query,cb);
        }
        var array=org.mockito.ArgumentCaptor.forClass(UUID[].class);
        verify(cb).value(array.capture());
        assertThat(array.getValue()).containsExactlyElementsOf(ids);
        verify(identity,never()).in(anyCollection());
        verify(cb).sql(eq("? = ANY(?)"),eq(Boolean.class),eq(identity),same(bound));
    }
}
