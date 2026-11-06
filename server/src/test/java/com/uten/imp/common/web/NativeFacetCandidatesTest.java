package com.uten.imp.common.web;

import jakarta.persistence.*;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class NativeFacetCandidatesTest {
    @Test void completeComputedRecordsUseTheSameKeywordAndBoundedPageContract() {
        var counts=new java.util.LinkedHashMap<String,Long>();
        for(int i=0;i<1005;i++)counts.put(String.format("客户%04d",i),2L);
        try(var scope=NativeFacetCandidates.open("value","客户",11,100)) {
            scope.completeRecords(counts);
            var result=scope.result(Map.of(),"current");
            assertThat(result.items()).hasSize(5);assertThat(result.hasMore()).isFalse();
            assertThat(result.items().getFirst().get("value")).isEqualTo("客户1000");
        }
        assertThat(NativeFacetCandidates.active()).isFalse();
    }
    @Test void usesOnlySelectedOriginalGroupedSqlAndCopiesBoundFiltersBeforeBoundedLiteralSearch() {
        EntityManager em=mock(EntityManager.class);Query original=mock(Query.class),paged=mock(Query.class),other=mock(Query.class);
        String sql="SELECT bill_no,COUNT(DISTINCT source_id) FROM facts WHERE owner_id=:owners GROUP BY bill_no ORDER BY 1";
        when(em.createNativeQuery(sql)).thenReturn(original);
        when(em.createNativeQuery("SELECT source_no,COUNT(*) FROM facts GROUP BY 1")).thenReturn(other);
        when(em.createNativeQuery(argThat((String value)->value!=null&&value.startsWith("SELECT candidate.value")))).thenReturn(paged);
        Parameter<Object> owner=mock();when(owner.getName()).thenReturn("owners");when(original.getParameters()).thenReturn(Set.of(owner));
        when(original.getParameterValue(owner)).thenReturn(List.of("actor-A"));
        when(paged.getResultList()).thenReturn(Arrays.asList(new Object[]{"0001 %_ 中文","0001 %_ 中文",7L},new Object[]{"0002","0002",3L},new Object[]{"0003","0003",1L}));
        try(var scope=NativeFacetCandidates.open("billNo","%_ 中文",6,2)) {
            assertThat(NativeFacets.rowsOf(NativeFacets.query(em,"sourceNo","SELECT source_no,COUNT(*) FROM facts GROUP BY 1"))).isEmpty();
            var rows=NativeFacets.rowsOf(NativeFacets.query(em,"billNo",sql));
            assertThat(rows).extracting(row->row.get("value")).containsExactly("0001 %_ 中文","0002");
            assertThat(scope.result(Map.of("billNo",rows),"scope-A")).isEqualTo(new NativeFacetCandidates.Page("billNo",rows,6,2,true,"scope-A"));
            verify(paged).setParameter("owners",List.of("actor-A"));verify(paged).setParameter("__nativeFacetKeyword","%_ 中文");
            verify(paged).setParameter("__nativeFacetLimit",3);verify(paged).setParameter("__nativeFacetOffset",10L);
            verify(original,never()).getResultList();verify(other,never()).getResultList();
        }
        assertThat(NativeFacetCandidates.active()).isFalse();
    }
    @Test void unregisteredRepeatedAndPositionalQueriesFailClosedAndCannotContaminateNextScope() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class),paged=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query,paged);when(query.getParameters()).thenReturn(Set.of());when(paged.getResultList()).thenReturn(List.of());
        try(var scope=NativeFacetCandidates.open("billNo","",1,100)) {
            assertThatThrownBy(()->NativeFacets.rowsOf(query)).isInstanceOf(IllegalStateException.class);
            assertThatThrownBy(()->scope.result(Map.of(),"v")).isInstanceOf(IllegalStateException.class);
        }
        try(var scope=NativeFacetCandidates.open("billNo","",1,100)) {
            var tagged=NativeFacets.query(em,"billNo","SELECT value,COUNT(*) FROM facts GROUP BY 1");NativeFacets.rowsOf(tagged);
            assertThatThrownBy(()->NativeFacets.rowsOf(tagged)).isInstanceOf(IllegalStateException.class);
        }
        assertThat(NativeFacetCandidates.active()).isFalse();
    }
    @Test void nestedScopesRestoreAndEmptyAuthorityIsExplicitWhileMissingFieldCannotHideUnmigratedQueries() {
        try(var outer=NativeFacetCandidates.open("billNo","",1,100)) {
            try(var inner=NativeFacetCandidates.open("sourceNo","",2,100)) {
                assertThat(inner.result(Map.of("sourceNo",List.of()),"v").items()).isEmpty();
            }
            assertThat(NativeFacetCandidates.current()).isSameAs(outer);
            assertThatThrownBy(()->outer.result(Map.of("other",List.of()),"v")).isInstanceOf(IllegalStateException.class);
            assertThat(outer.result(Map.of(),"v").items()).isEmpty();
        }
        assertThatThrownBy(()->NativeFacetCandidates.open("unknown_field","",1,100)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->NativeFacetCandidates.open("billNo","",0,100)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->NativeFacetCandidates.open("billNo","",1,101)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->NativeFacetCandidates.open("billNo","",(long)Integer.MAX_VALUE+1,100)).isInstanceOf(ApiException.class);
    }
    @Test void positionalApplicationBindingsAreNotAccepted() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class),paged=mock(Query.class);Parameter<Object> positional=mock();
        when(em.createNativeQuery(anyString())).thenReturn(query,paged);when(query.getParameters()).thenReturn(Set.of(positional));
        try(var scope=NativeFacetCandidates.open("billNo","",1,100)) {
            var tagged=NativeFacets.query(em,"billNo","SELECT value,COUNT(*) FROM facts WHERE owner_id=? GROUP BY 1");
            assertThatThrownBy(()->NativeFacets.rowsOf(tagged)).isInstanceOf(IllegalStateException.class).hasMessageContaining("named");
            verify(paged,never()).getResultList();
        }
    }

    @Test void explicitLabeledQueryMatchesNamesAndPreservesIdLabelsAndOriginalCounts() {
        EntityManager em=mock(EntityManager.class);Query original=mock(Query.class),paged=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(original,paged);when(original.getParameters()).thenReturn(Set.of());
        when(paged.getResultList()).thenReturn(java.util.Collections.singletonList(new Object[]{"supplier-id","中文供应商%_",17L}));
        try(var scope=NativeFacetCandidates.open("supplierId","中文 %_",1,100)) {
            assertThat(NativeFacets.wants("supplierId")).isTrue();assertThat(NativeFacets.wants("billNo")).isFalse();
            var rows=NativeFacets.rowsOf(NativeFacets.queryLabeled(em,"supplierId","SELECT supplier_id,supplier_name,COUNT(*) FROM facts GROUP BY 1,2"));
            assertThat(rows).singleElement().satisfies(row->{assertThat(row.get("value")).isEqualTo("supplier-id");assertThat(row.get("label")).isEqualTo("中文供应商%_");assertThat(row.get("count")).isEqualTo(17L);});
            var sql=org.mockito.ArgumentCaptor.forClass(String.class);verify(em,times(2)).createNativeQuery(sql.capture());
            assertThat(sql.getAllValues().get(1)).contains("raw_candidate(value,label,bucket_count)","candidate.label","LIMIT :__nativeFacetLimit");
            verify(paged).setHint("jakarta.persistence.query.timeout",30_000);verify(paged).setParameter("__nativeFacetLimit",101);
        }
        assertThat(NativeFacets.wants("billNo")).isTrue();
    }
    @Test void publicationFailsClosedWithoutTheOwningSnapshotAndDoesNotInventFallbackProof() {
        try(var scope=NativeFacetCandidates.open("billNo","",1,100)) {
            scope.requireSnapshot();
            assertThatThrownBy(()->scope.result(Map.of(),"auth")).isInstanceOf(IllegalStateException.class).hasMessageContaining("owning snapshot");
            scope.snapshot("auth","a".repeat(64),"b".repeat(64));
            var page=scope.result(Map.of(),"auth");assertThat(page.readSnapshotRevision()).isEqualTo("a".repeat(64));assertThat(page.readDataVersion()).isEqualTo("b".repeat(64));
            assertThatThrownBy(()->scope.result(Map.of(),"other")).isInstanceOf(ApiException.class);
        }
    }

    @Test void nonselectedJdbcProjectionsDoNotExecuteOrBindAnyBusinessQuery() {
        var jdbc=mock(org.springframework.jdbc.core.JdbcTemplate.class);var named=mock(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate.class);
        try(var scope=NativeFacetCandidates.open("billNo","",1,100)) {
            assertThat(NativeFacets.jdbcRows(jdbc,"other","SELECT value,COUNT(*) FROM authority_facts GROUP BY value",new Object[0],false)).isEmpty();
            assertThat(NativeFacets.jdbcRows(named,"other","SELECT value,COUNT(*) FROM authority_facts GROUP BY value",new org.springframework.jdbc.core.namedparam.MapSqlParameterSource(),false)).isEmpty();
            verifyNoInteractions(jdbc,named);
        }
    }
}
