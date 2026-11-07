package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.*;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ReportTablePdfWorkerTest {
    @TempDir Path directory;
    @AfterEach void restoreSnapshot(){TransactionSynchronizationManager.clear();}

    @Test void pdfWorkerReadsAllAuthoritativeBatchesIncludingTheLastRemainder() throws Exception {
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        var repository=mock(ReportExportRepository.class);var service=mock(ReportExportService.class);
        var source=mock(ReportExportSource.class);var pdf=mock(TabularPdfExportService.class);
        var document=mock(StreamingDocumentWriter.class);var transactions=mock(PlatformTransactionManager.class);
        var job=mock(ReportExportRepository.Job.class);
        when(service.requireStorage()).thenReturn(directory);when(pdf.openDocumentStream(directory)).thenReturn(document);
        when(transactions.getTransaction(any())).thenAnswer(call->new SimpleTransactionStatus());
        when(repository.heartbeat(eq(job),anyInt())).thenReturn(true);
        var columns=List.of(new ExportColumn("id","系统标识",ExportColumn.TEXT));
        var request=new ReportExportRequest(UUID.randomUUID(),"sales","ORDER/detail",Map.of(),null,null,null,"pdf");
        when(source.read(request)).thenAnswer(call->{
            ExportPageSink.current().accept(new ExportPayload(columns,
                    IntStream.range(0,500).mapToObj(i->Map.<String,Object>of("id",Integer.toString(i))).toList(),501));
            return new ExportPayload(columns,List.of(Map.of("id","500")),501);
        });
        var pages=new ReportTablePdfPages(new ExportTableProjectionService(mock(PlatformColumnService.class)));
        try(var worker=new WorkerLifetime(new ReportExportWorker(repository,service,source,mock(SubmitterPrincipalRestorer.class),
                mock(XlsxExportService.class),pdf,pages,mock(JdbcTemplate.class),transactions))) {
            Object writer=ReflectionTestUtils.invokeMethod(worker.value,"openWriter",request,job,Long.MAX_VALUE);
            ReflectionTestUtils.invokeMethod(writer,"readSource");
            var capture=org.mockito.ArgumentCaptor.forClass(DocumentPageSink.Page.class);
            verify(document,times(4)).accept(capture.capture());
            assertThat(capture.getAllValues()).extracting(page->page.rows().size()).containsExactly(200,200,100,1);
            assertThat(capture.getAllValues()).flatExtracting(DocumentPageSink.Page::rows).extracting(row->row.get("id"))
                    .containsExactlyElementsOf(IntStream.range(0,501).mapToObj(Integer::toString).toList());
            assertThat(ExportPageSink.current()).isNull();
            ReflectionTestUtils.invokeMethod(writer,"close");verify(document).close();
        }
    }

    private static final class WorkerLifetime implements AutoCloseable {
        final ReportExportWorker value;
        WorkerLifetime(ReportExportWorker value){this.value=value;}
        @Override public void close(){value.close();}
    }
}
