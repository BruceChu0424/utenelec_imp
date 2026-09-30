package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class DocumentPlatformColumnAdapterTest {
    private final EntityManager em=mock(EntityManager.class);
    private final SecurityContextCurrentUser user=mock(SecurityContextCurrentUser.class);
    private final ObjectMapper json=new ObjectMapper();
    private final UUID doc=UUID.randomUUID(),line=UUID.randomUUID();
    private final Object entity=new Object();
    private void permissions(String... rights){when(user.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"staff",Set.of(rights),false,true,false)));}
    private DocumentPlatformColumnAdapter adapter(Map<String,Object> header){
        Query query=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{line,doc}));
        when(em.find(Object.class,doc,LockModeType.PESSIMISTIC_WRITE)).thenReturn(entity);
        return new DocumentPlatformColumnAdapter("test_item","Test",user,em,json,Set.of("test:view"),Set.of("test:edit"),
            Set.of("test:price"),Object.class,"SELECT id,parent_id FROM test_items WHERE id IN (:ids)",id->header,
            (id,node)->DocumentPlatformColumnAdapter.draft(node)&&node.path("writable").asBoolean(false),
            List.of(new PlatformColumnResourceAdapter.FactDefinition("qty","Quantity",false),new PlatformColumnResourceAdapter.FactDefinition("price","Price",true)))
            .documentCreateAuthorities(Set.of("test:create"));
    }
    private Map<String,Object> header(int status,boolean masked){return Map.of("id",doc,"status",status,"writable",true,"priceMasked",masked,
        "items",List.of(Map.of("id",line,"qty",1,"qtyExact","1.000001","price",9)));}

    @Test void exactFactsAndPermissionMaskingUseTheAuthorizedDomainDetail(){
        permissions("test:view","test:edit","test:price");
        var result=adapter(header(0,true)).authorize(Set.of(line),false).get(line);
        assertThat(result.facts()).containsExactly(Map.entry("qty",new BigDecimal("1.000001")));
        assertThat(result.priceVisible()).isFalse();
        verify(em,never()).refresh(any(),any(LockModeType.class));
    }
    @Test void writeLocksHeaderBeforeLifecycleInspectionAndCannotChangeApprovedRows(){
        permissions("test:view","test:edit");
        assertThatThrownBy(()->adapter(header(1,false)).authorize(Set.of(line),true)).isInstanceOf(ApiException.class);
        var order=inOrder(em);order.verify(em).createNativeQuery(anyString());order.verify(em).flush();
        order.verify(em).find(Object.class,doc,LockModeType.PESSIMISTIC_WRITE);
        order.verify(em).refresh(entity,LockModeType.PESSIMISTIC_WRITE);
    }
    @Test void createAuthorityCannotWriteExistingRowsAndRequiresInTransactionInsertEvidence(){
        permissions("test:view","test:create");
        var adapter=adapter(header(0,false));
        assertThat(adapter.canCreate()).isTrue();assertThat(adapter.canWrite()).isFalse();
        assertThatCode(()->adapter.requireDefinitionAccess(true)).doesNotThrowAnyException();
        assertThatThrownBy(()->adapter.requireDocumentSaveAccess(false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->adapter.authorize(Set.of(line),true)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->adapter.authorizeCreated(Set.of(line))).isInstanceOf(ApiException.class);
        try(var context=PlatformColumnSaveLineage.begin(Set.of())){
            PlatformColumnSaveLineage.recordPersisted(doc);PlatformColumnSaveLineage.recordPersisted(line);
            assertThat(adapter.authorizeCreated(Set.of(line)).get(line).canWrite()).isTrue();
        }
    }
    @Test void emptyDocumentStillLocksAndAuthorizesParentBeforeFindingRows(){
        permissions("test:view","test:edit");
        var adapter=adapter(header(0,false)).documentRows("SELECT id FROM test_items WHERE parent_id=:document");
        Query query=mock(Query.class);when(em.createNativeQuery("SELECT id FROM test_items WHERE parent_id=:document")).thenReturn(query);
        when(query.setParameter("document",doc)).thenReturn(query);when(query.getResultList()).thenReturn(List.of());
        assertThat(adapter.recordIdsForDocument(doc)).isEmpty();
        var order=inOrder(em);order.verify(em).flush();order.verify(em).find(Object.class,doc,LockModeType.PESSIMISTIC_WRITE);
        order.verify(em).refresh(entity,LockModeType.PESSIMISTIC_WRITE);order.verify(em).createNativeQuery("SELECT id FROM test_items WHERE parent_id=:document");
    }
}
