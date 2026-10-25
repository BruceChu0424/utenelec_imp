package com.uten.imp.common.history;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.HeaderColumnFilter;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.production.plan.dto.PlanDetail;
import com.uten.imp.features.sales.order.SalesOrder;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.subcontract.order.dto.OrderQueryFilter;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

class ImportedBusinessDocumentScopeTest {
    @AfterEach void clearRequest() { RequestContextHolder.resetRequestAttributes(); }

    private static void origin(String value) {
        var request = new MockHttpServletRequest();
        if (value != null) request.setParameter("originScope", value);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
    }

    @Test void currentIsDefaultAndInvalidOriginIsRejected() {
        assertEquals(ImportedBusinessDocumentScope.Origin.CURRENT, ImportedBusinessDocumentScope.origin());
        origin("legacy");
        assertEquals(ImportedBusinessDocumentScope.Origin.LEGACY, ImportedBusinessDocumentScope.origin());
        origin("CURRENT OR TRUE");
        assertThrows(ApiException.class, ImportedBusinessDocumentScope::origin);
    }

    @ParameterizedTest @ValueSource(strings={"LEGACY", "ALL"})
    void historyIgnoresLifecycleButPreservesExplicitDateSearchAndColumnPrivacy(String scope) {
        origin(scope);
        UUID supplier = UUID.randomUUID();
        var original = new OrderQueryFilter("explicit keyword", supplier, null, (short)-1,
                LocalDate.of(2014,1,1), LocalDate.of(2026,10,23), false, "PENDING", "exact bill")
                .withHistory(true,false).withHeaders(new HeaderColumnFilter(Map.of(
                        "amountMin","12.50", "apPosted","true", "recordOrigin","LEGACY")));
        var history = ImportedBusinessDocumentScope.historyFilter(original);
        assertNull(history.status()); assertNull(history.closed()); assertNull(history.financeApproval());
        assertEquals(original.dateFrom(),history.dateFrom()); assertEquals(original.dateTo(),history.dateTo());
        assertEquals(supplier,history.supplierId()); assertEquals("exact bill",history.billNo());
        assertEquals("explicit keyword",history.keyword()); assertTrue(history.includeDeleted());
        assertEquals(Map.of("amountMin","12.50","recordOrigin","LEGACY"),history.headerFilters().values());
        assertEquals((short)-1,original.status()); // A query never rewrites source state.
    }

    @Test void nativeFilterAndCallerDataScopeStayUnchanged() {
        origin("CURRENT");
        var filter=new OrderQueryFilter("native",UUID.randomUUID(),UUID.randomUUID(),(short)0,
                LocalDate.now().minusDays(2),LocalDate.now(),false,"NONE");
        assertSame(filter,ImportedBusinessDocumentScope.historyFilter(filter));
    }

    @Test @SuppressWarnings("unchecked") void allHistoryIncludesImportsOutsideNativeWorkflowSegment() {
        origin("ALL");
        Root<SalesOrder> root=mock(Root.class); CriteriaBuilder cb=mock(CriteriaBuilder.class);
        Expression<Boolean> imported=mock(Expression.class);Predicate old=mock(Predicate.class), marker=mock(Predicate.class), both=mock(Predicate.class);
        doReturn(SalesOrder.class).when(root).getJavaType();
        when(cb.function(eq("fn_imported_business_document"),eq(Boolean.class),any(),any())).thenReturn(imported);
        when(cb.isTrue(imported)).thenReturn(marker);when(cb.or(marker,old)).thenReturn(both);
        assertSame(both,ImportedBusinessDocumentScope.lifecycle(root,cb,old));
        Predicate nativeOnly=mock(Predicate.class);when(cb.isFalse(imported)).thenReturn(nativeOnly);
        assertSame(nativeOnly,ImportedBusinessDocumentScope.nativeOnly(root,cb));
    }

    @Test void legacyMutationFailsBeforeAnyPersistenceAndMasterRemainsMutable() {
        SalesOrder history=new SalesOrder();history.setLegacyId(7);history.setStatus((short)-1);
        EntityManager em=mock(EntityManager.class);
        assertThrows(ApiException.class,()->ImportedBusinessDocumentPolicy.mutable(em,"sales_orders",history));
        verifyNoInteractions(em);
        Goods master=new Goods();master.setLegacyId(7);
        assertSame(master,ImportedBusinessDocumentPolicy.mutable(master));
    }

    @Test void nativeLookingDocumentWithRealImportProvenanceIsStillRejected() {
        SalesOrder row=new SalesOrder();row.setId(UUID.randomUUID());
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery("SELECT fn_imported_business_document(:table,:id)")).thenReturn(query);
        when(query.getSingleResult()).thenReturn(true);
        assertThrows(ApiException.class,()->ImportedBusinessDocumentPolicy.mutable(em,"sales_orders",row));
        when(query.getSingleResult()).thenReturn(false);
        assertSame(row,ImportedBusinessDocumentPolicy.mutable(em,"sales_orders",row));
    }

    @ParameterizedTest @ValueSource(shorts={-1,0,1})
    void importedDtoKeepsRawStatusAndCancellationWhileDisablingActions(short status) throws Exception {
        PlanDetail plan=detail(PlanDetail.class,status,77);
        assertTrue(plan.isLegacyImported());assertTrue(plan.isHistoryReadOnly());
        assertTrue(plan.isCanceled());assertEquals(status,plan.getStatus());assertEquals(List.of(),plan.getAllowedActions());
        OrderDetail order=detail(OrderDetail.class,status,77);
        assertFalse(order.isWritable());assertEquals(status,order.getStatus());
        var json=new ObjectMapper().valueToTree(order);
        assertTrue(json.path("legacyImported").asBoolean());assertTrue(json.path("historyReadOnly").asBoolean());
        assertFalse(json.path("writable").asBoolean());
    }

    @Test void provenanceOnlyMetadataAndOrdinaryNativeActionsRemainTruthful() throws Exception {
        OrderDetail nativeOrder=detail(OrderDetail.class,(short)0,null);
        assertFalse(nativeOrder.isLegacyImported());assertFalse(nativeOrder.isHistoryReadOnly());assertTrue(nativeOrder.isWritable());
        nativeOrder.setLegacyImported(true);
        assertTrue(nativeOrder.isLegacyImported());assertTrue(nativeOrder.isHistoryReadOnly());assertFalse(nativeOrder.isWritable());
    }

    @Test void retainedMetadataBindsActualDatabaseOriginWithoutChangingDeletionOrStatus() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(startsWith("SELECT id, fn_imported_business_document"))).thenReturn(query);
        UUID id=UUID.randomUUID();when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{id,true}));
        var reader=new RetainedRecordReader(em,new ObjectMapper());
        var metadata=reader.metadata("sales_orders",List.of(new RetainedRecordReader.DocumentRef(id,false,null)),false).get(id);
        assertTrue(metadata.isLegacyImported());assertTrue(metadata.isHistoryReadOnly());assertFalse(metadata.isDeleted());
        assertNull(metadata.getDeletedAt());
    }

    private static <T> T detail(Class<T> type,short status,Integer legacy) throws Exception {
        var constructor=type.getConstructors()[0];var parameters=constructor.getParameters();Object[] values=new Object[parameters.length];
        for(int index=0;index<parameters.length;index++){
            var parameter=parameters[index];String name=parameter.getName();Class<?> valueType=parameter.getType();
            if(name.equals("legacyId"))values[index]=legacy;
            else if(name.equals("status"))values[index]=status;
            else if(name.equals("allowedActions"))values[index]=List.of("APPROVE","EDIT");
            else if(valueType==boolean.class)values[index]=name.equals("canceled")||name.equals("writable")||name.matches("can[A-Z].*");
            else if(valueType==int.class)values[index]=0;
            else if(valueType==long.class)values[index]=0L;
            else if(valueType==BigDecimal.class)values[index]=new BigDecimal("12.3450");
            else if(valueType==List.class)values[index]=List.of();
        }
        return type.cast(constructor.newInstance(values));
    }
}
