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
    @Test void absentRawSelectionDoesNotAddAnUnknownFieldToNativeCreationProof() throws Exception {
        var projection = new TableColumnProjection("master.unit", "master_unit", List.of(
                new TableColumnProjection.Column("code", "Code", 120d, "text", null)));
        assertThat(new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(projection)).doesNotContain("rowSelection");
    }
    @Test void repositoryReceivesOriginalPredicateAndSelectedIdentityIntersection() {
        UUID id = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        @SuppressWarnings("unchecked") JpaSpecificationExecutor<Object> repo = mock(JpaSpecificationExecutor.class);
        Root<Object> root = mock(Root.class); CriteriaQuery<?> query = mock(CriteriaQuery.class);
        CriteriaBuilder cb = mock(CriteriaBuilder.class); Path<Object> identity = mock(Path.class);
        Predicate authorised = mock(Predicate.class), selected = mock(Predicate.class), intersection = mock(Predicate.class);
        var originalVisited = new java.util.concurrent.atomic.AtomicBoolean();
        Specification<Object> original = (r, q, b) -> { originalVisited.set(true); return authorised; };
        when(root.get("id")).thenReturn(identity); when(identity.in(Set.of(id))).thenReturn(selected);
        when(cb.and(authorised, selected)).thenReturn(intersection);
        Pageable page = PageRequest.of(0, 100);
        when(repo.findAll(any(Specification.class), eq(page))).thenAnswer(call -> {
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
            assertThatThrownBy(() -> MasterExportSource.exportEntities(em, List.of(), 100000,
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
    @Test void fiftyThousandSelectedIdentitiesStayBelowThePostgresParameterLimitWithHibernatePadding(){
        List<UUID> ids=java.util.stream.IntStream.rangeClosed(1,50000).mapToObj(i->new UUID(1,i)).toList();
        Root<Object> root=mock(Root.class);CriteriaQuery<?> query=mock(CriteriaQuery.class);CriteriaBuilder cb=mock(CriteriaBuilder.class);
        Path<Object> identity=mock(Path.class);when(root.get("id")).thenReturn(identity);
        List<UUID> actual=new ArrayList<>();var padded=new java.util.concurrent.atomic.AtomicInteger();
        when(identity.in(anyCollection())).thenAnswer(call->{
            Collection<UUID> chunk=call.getArgument(0);assertThat(chunk.size()).isBetween(1,1024);actual.addAll(chunk);
            padded.addAndGet(Integer.highestOneBit(chunk.size()-1)<<1);return mock(Predicate.class);
        });
        try(var ignored=MasterExportSelection.open(ids)){
            MasterExportSelection.<Object>intersect(null).toPredicate(root,query,cb);
        }
        assertThat(actual).containsExactlyElementsOf(ids);assertThat(padded.get()).isEqualTo(50176).isLessThan(65535);
        var combined=org.mockito.ArgumentCaptor.forClass(Predicate[].class);
        verify(cb).or(combined.capture());assertThat(combined.getValue()).hasSize(49);
    }
}
