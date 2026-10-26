package com.uten.imp.audit;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AuditSessionTableExportServiceTest {
    private final AuditSessionQueryService query=mock(AuditSessionQueryService.class);
    private final AuditSessionTableExportService service=new AuditSessionTableExportService(query);
    private final UUID actor=UUID.randomUUID();
    private final LocalDate from=LocalDate.of(2026,9,1),to=from.plusDays(1);
    @Test void exportUsesVisibleSessionSchemaAndFreezesOneSnapshotAcrossAllPages() {
        var row=mock(AuditSessionRow.class);
        when(row.actorDisplay()).thenReturn("员工");when(row.operationCount()).thenReturn(4L);
        when(query.sessionsForExport(actor,from,to,1,100,99L,null)).thenReturn(new AuditSessionPageResponse(Collections.nCopies(100,row),1,100,101,2,99));
        when(query.sessionsForExport(actor,from,to,2,100,99L,101L)).thenReturn(new AuditSessionPageResponse(List.of(row),2,100,101,2,99));
        var result=service.export(actor,from,to,99L,1000);
        assertThat(result.columns()).extracting(ExportColumn::key).containsExactly("actor","login","status","device","operations","failures","postLogout","logout","credential");
        assertThat(result.rows()).hasSize(101);
        assertThat(result.rows().getFirst()).containsEntry("operations",4L).containsEntry("actor","员工");
        verify(query).sessionsForExport(actor,from,to,2,100,99L,101L);
    }
    @Test void exceedsConfiguredLimitOrDriftingSnapshotNeverSilentlyTruncates() {
        when(query.sessionsForExport(actor,from,to,1,100,99L,null)).thenReturn(new AuditSessionPageResponse(List.of(),1,100,21,2,99));
        assertThatThrownBy(()->service.export(actor,from,to,99L,10)).isInstanceOf(ApiException.class);
        when(query.sessionsForExport(actor,from,to,2,100,99L,21L)).thenReturn(new AuditSessionPageResponse(List.of(),2,100,21,2,100));
        assertThatThrownBy(()->service.export(actor,from,to,99L,100)).isInstanceOf(ApiException.class);
    }
}
