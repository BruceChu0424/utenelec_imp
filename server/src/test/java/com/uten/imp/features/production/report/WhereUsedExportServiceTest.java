package com.uten.imp.features.production.report;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.export.DocumentPageSink;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.time.LocalDate;
import java.util.*;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WhereUsedExportServiceTest {
    final ProductionWhereUsedQueryService query = mock(ProductionWhereUsedQueryService.class);
    final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    final EntityManager em = mock(EntityManager.class);
    final EmployeeNameResolver employees = mock(EmployeeNameResolver.class);
    final WhereUsedExportService service = new WhereUsedExportService(query, currentUser, em, employees);
    @AfterEach void clear(){TransactionSynchronizationManager.clear();SecurityContextHolder.clearContext();}
    private AuthUser principal(Set<String> permissions){return new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"server-account",permissions,false,true,false);}
    private void snapshot(AuthUser user,boolean active,boolean readOnly,int isolation) {
        TransactionSynchronizationManager.setActualTransactionActive(active);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(readOnly);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(isolation);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
    }
    private void identities(UUID material,AuthUser user) {
        Query identity=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(identity);
        when(identity.setParameter("id",material)).thenReturn(identity);
        when(identity.getResultList()).thenReturn(Collections.singletonList(new Object[]{"M001","当前组件","个"}));
        when(currentUser.get()).thenReturn(Optional.of(user));when(employees.nameWithCodeOf(user.getEmployeeId())).thenReturn("服务器姓名(E001)");
    }

    @Test void exportsAllFilteredPagesAndServerResolvedOperatorInsteadOfPhoneAccount() {
        UUID material = UUID.randomUUID(), employee = UUID.randomUUID();
        LocalDate from = LocalDate.of(2026, 9, 1), to = LocalDate.of(2026, 10, 20);
        List<ReportColumn> columns = List.of(ReportColumn.text("goodsName", "产品名称"));
        var first = new ReportTableResponse(columns, rows(0, 200), Map.of(), 1, 200, 250, 2);
        var second = new ReportTableResponse(columns, rows(200, 250), Map.of(), 2, 200, 250, 2);
        when(query.whereUsedExportPage(material, "history", from, to, 1, 200, "goodsName", "desc",true)).thenReturn(first);
        when(query.whereUsedExportPage(material, "history", from, to, 2, 200, "goodsName", "desc",false)).thenReturn(second);
        Query identity = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(identity);
        when(identity.setParameter("id", material)).thenReturn(identity);
        when(identity.getResultList()).thenReturn(Collections.singletonList(new Object[]{"M001", "当前组件", "个"}));
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), employee,
                "13912345678", Set.of(), false, true, false)));
        when(employees.nameWithCodeOf(employee)).thenReturn("张三(E0001)");

        var document = service.document(material, "history", from, to, "goodsName", "desc");

        assertEquals(250, document.sections().getFirst().rows().size());
        assertEquals("产品249", document.sections().getFirst().rows().getLast().get("goodsName"));
        assertTrue(document.metadata().contains("操作员：张三(E0001)"));
        assertFalse(document.metadata().toString().contains("13912345678"));
        assertTrue(document.metadata().contains("历史日期：2026-09-01 至 2026-10-20"));
        assertTrue(document.metadata().contains("筛选来源：全部历史"));
        verify(query).whereUsedExportPage(material, "history", from, to, 2, 200, "goodsName", "desc",false);
    }

    @Test void oversizedExportStopsBeforeIdentityOrFurtherPageReads() {
        UUID material = UUID.randomUUID();
        when(query.whereUsedExportPage(material, "all", null, null, 1, 200, null, null,true)).thenReturn(
                new ReportTableResponse(List.of(ReportColumn.text("goodsName", "产品名称")), List.of(),
                        Map.of(), 1, 200, 50_001, 251));
        assertThrows(ApiException.class, () -> service.document(material, "all", null, null, null, null));
        verifyNoInteractions(em, currentUser, employees);
        verify(query).whereUsedExportPage(material, "all", null, null, 1, 200, null, null,true);
        verifyNoMoreInteractions(query);
    }

    @Test void synchronousCompatibilityRefusesLargeResultsInsteadOfMaterializingOrTruncating() {
        UUID material=UUID.randomUUID();
        when(query.whereUsedExportPage(material,"all",null,null,1,200,null,null,true)).thenReturn(new ReportTableResponse(
                List.of(ReportColumn.text("goodsName","产品名称")),rows(0,200),Map.of(),1,200,501,3));
        var failure=assertThrows(ApiException.class,()->service.document(material,"all",null,null,null,null));
        assertTrue(failure.getMessage().contains("后台"));verifyNoInteractions(em,currentUser,employees);
    }

    @Test void streamingFansEachPageIntoIndependentEvidenceAndCountsOnlyProducts()throws Exception {
        UUID material=UUID.randomUUID();var user=principal(Set.of("production_where_used:view","production_where_used:export"));
        snapshot(user,true,true,java.sql.Connection.TRANSACTION_REPEATABLE_READ);identities(material,user);
        var columns=List.of(ReportColumn.text("goodsName","产品名称"),ReportColumn.text("goodsCode","产品编号"));
        List<Map<String,Object>> all=IntStream.range(0,1001).mapToObj(index->{
            Map<String,Object> row=new LinkedHashMap<>();row.put("goodsName","产品"+index);row.put("goodsCode","P"+index);
            row.put("__currentBom",index%2==0);row.put("__currentDirectQty",new java.math.BigDecimal("0.123456789012345678901"));
            row.put("__legacyEvidenceCount",index%3==0?1:0);row.put("legacyRequiredQty",new java.math.BigDecimal("5.0001"));
            return row;
        }).toList();
        for(int page=1;page<=6;page++) {
            var subset=all.subList((page-1)*200,Math.min(all.size(),page*200));
            when(query.whereUsedExportPage(material,"history",null,null,page,200,null,null,page==1)).thenReturn(
                    new ReportTableResponse(columns,subset,Map.of(),page,200,1001,6,Map.of("unattributedDemandCount",7,"unattributedDemandQty",new java.math.BigDecimal("2.1001"))));
        }
        final DocumentPageSink.Header[] header={null};var batches=new ArrayList<DocumentPageSink.Page>();
        try(var sink=DocumentPageSink.open(new DocumentPageSink.Consumer(){
            @Override
            public void begin(DocumentPageSink.Header value){header[0]=value;}@Override public void accept(DocumentPageSink.Page page){batches.add(page);}
        })){service.streamDocument(material,"history",null,null,null,null);}
        assertEquals(1001,header[0].expectedPrimaryRows());assertEquals(5,header[0].sections().size());
        assertTrue(header[0].metadata().contains("操作员：服务器姓名(E001)"));
        assertTrue(header[0].metadata().stream().anyMatch(value->value.contains("7 条，需求量 2.1001")));
        assertTrue(batches.stream().allMatch(page->page.rows().size()<=200));
        assertEquals(List.of(200,200,200,200,200,1),batches.stream().filter(page->page.sectionId().equals("section-0")).map(page->page.rows().size()).toList());
        assertEquals(all,batches.stream().filter(page->page.sectionId().equals("section-0")).flatMap(page->page.rows().stream()).toList());
        assertEquals(501,batches.stream().filter(page->page.sectionId().equals("section-1")).mapToInt(page->page.rows().size()).sum());
        assertEquals(334,batches.stream().filter(page->page.sectionId().equals("section-3")).mapToInt(page->page.rows().size()).sum());
        assertFalse(batches.stream().anyMatch(page->Set.of("section-2","section-4").contains(page.sectionId())));
        assertEquals("个",header[0].sections().get(1).columns().get(4).unitLabel());
        assertNull(header[0].sections().get(3).columns().get(5).unitLabel(),"Historical quantities never inherit the current master unit");
        verify(query).whereUsedExportPage(material,"history",null,null,1,200,null,null,true);
        verify(query).whereUsedExportPage(material,"history",null,null,6,200,null,null,false);
    }

    @Test void streamBridgeRequiresItsOwnPermissionPairAndWorkerSnapshotBeforeFacts() {
        var user=principal(Set.of("production_where_used:view","production_where_used:export"));
        snapshot(user,true,true,java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        assertThrows(IllegalStateException.class,()->service.streamDocument(UUID.randomUUID(),"all",null,null,null,null));
        var noop=new DocumentPageSink.Consumer(){@Override public void begin(DocumentPageSink.Header header){}@Override public void accept(DocumentPageSink.Page page){}};
        try(var sink=DocumentPageSink.open(noop)) {
            for(var invalid:List.of(new Object[]{false,true,java.sql.Connection.TRANSACTION_REPEATABLE_READ},
                    new Object[]{true,false,java.sql.Connection.TRANSACTION_REPEATABLE_READ},new Object[]{true,true,java.sql.Connection.TRANSACTION_READ_COMMITTED})) {
                snapshot(user,(boolean)invalid[0],(boolean)invalid[1],(int)invalid[2]);
                assertThrows(IllegalStateException.class,()->service.streamDocument(UUID.randomUUID(),"all",null,null,null,null));
            }
            for(var permissions:List.of(Set.of("production_where_used:view"),Set.of("production_report:view","production_report:export"))) {
                snapshot(principal(permissions),true,true,java.sql.Connection.TRANSACTION_REPEATABLE_READ);
                assertThrows(ApiException.class,()->service.streamDocument(UUID.randomUUID(),"all",null,null,null,null));
            }
        }
        verifyNoInteractions(query,em,currentUser,employees);
    }

    @Test void incompleteOrChangedPageIsAnErrorAndNeverAValidDocument() {
        UUID material=UUID.randomUUID();var user=principal(Set.of("production_where_used:view","production_where_used:export"));
        snapshot(user,true,true,java.sql.Connection.TRANSACTION_REPEATABLE_READ);identities(material,user);
        var columns=List.of(ReportColumn.text("goodsName","产品名称"));
        when(query.whereUsedExportPage(material,"all",null,null,1,200,null,null,true)).thenReturn(new ReportTableResponse(columns,rows(0,200),Map.of(),1,200,201,2));
        when(query.whereUsedExportPage(material,"all",null,null,2,200,null,null,false)).thenReturn(new ReportTableResponse(columns,List.of(),Map.of(),2,200,201,2));
        var noop=new DocumentPageSink.Consumer(){@Override public void begin(DocumentPageSink.Header header){}@Override public void accept(DocumentPageSink.Page page){}};
        try(var sink=DocumentPageSink.open(noop)) {
            assertThrows(IllegalStateException.class,()->service.streamDocument(material,"all",null,null,null,null));
        }
    }

    private static List<Map<String, Object>> rows(int start, int end) {
        return IntStream.range(start, end).mapToObj(index -> Map.<String, Object>of("goodsName", "产品" + index)).toList();
    }
}
