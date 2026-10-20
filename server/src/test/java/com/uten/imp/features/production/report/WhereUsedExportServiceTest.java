package com.uten.imp.features.production.report;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

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

    @Test void exportsAllFilteredPagesAndServerResolvedOperatorInsteadOfPhoneAccount() {
        UUID material = UUID.randomUUID(), employee = UUID.randomUUID();
        LocalDate from = LocalDate.of(2026, 9, 1), to = LocalDate.of(2026, 10, 20);
        List<ReportColumn> columns = List.of(ReportColumn.text("goodsName", "产品名称"));
        var first = new ReportTableResponse(columns, rows(0, 200), Map.of(), 1, 200, 250, 2);
        var second = new ReportTableResponse(columns, rows(200, 250), Map.of(), 2, 200, 250, 2);
        when(query.whereUsed(material, "history", from, to, 1, 200, "goodsName", "desc")).thenReturn(first);
        when(query.whereUsed(material, "history", from, to, 2, 200, "goodsName", "desc")).thenReturn(second);
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
        verify(query).whereUsed(material, "history", from, to, 2, 200, "goodsName", "desc");
    }

    @Test void oversizedExportStopsBeforeIdentityOrFurtherPageReads() {
        UUID material = UUID.randomUUID();
        when(query.whereUsed(material, "all", null, null, 1, 200, null, null)).thenReturn(
                new ReportTableResponse(List.of(ReportColumn.text("goodsName", "产品名称")), List.of(),
                        Map.of(), 1, 200, 50_001, 251));
        assertThrows(ApiException.class, () -> service.document(material, "all", null, null, null, null));
        verifyNoInteractions(em, currentUser, employees);
        verify(query).whereUsed(material, "all", null, null, 1, 200, null, null);
        verifyNoMoreInteractions(query);
    }

    private static List<Map<String, Object>> rows(int start, int end) {
        return IntStream.range(start, end).mapToObj(index -> Map.<String, Object>of("goodsName", "产品" + index)).toList();
    }
}
