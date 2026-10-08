package com.uten.imp.features.ai.job;
import com.uten.imp.application.port.AiJobHandler.AiJobInput;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
class AiInputOriginalStorageContractTest {
    @Test void otherRegisteredJobKindsKeepTheirExistingUsageContractWithoutASalesOriginal() {
        var jdbc=mock(NamedParameterJdbcTemplate.class);UUID job=UUID.randomUUID();
        when(jdbc.queryForList("SELECT kind FROM ai_jobs WHERE id=:job",Map.of("job",job),String.class)).thenReturn(List.of("PLATFORM_TEST"));
        var files=mock(ImmutableDocumentStore.class);var store=new AiInputOriginalStore(jdbc,files,mock(StorageService.class),
            mock(SecurityContextCurrentUser.class),mock(AuditService.class),List.of());
        assertThatCode(()->store.bind(job,UUID.randomUUID(),"quote",UUID.randomUUID())).doesNotThrowAnyException();
        verify(jdbc,never()).update(anyString(),anyMap());verifyNoInteractions(files);
    }
    @Test void disabledAndUnsupportedProviderCannotPretendToCaptureAnOriginal() {
        var jdbc=mock(NamedParameterJdbcTemplate.class);var files=mock(ImmutableDocumentStore.class);var storage=mock(StorageService.class);
        var store=new AiInputOriginalStore(jdbc,files,storage,mock(SecurityContextCurrentUser.class),mock(AuditService.class),List.of());
        assertThatThrownBy(()->store.requireCaptureAvailable("SALES_DOCUMENT_INTAKE")).hasMessageContaining("未启用");
        when(storage.isEnabled()).thenReturn(true);when(storage.backend()).thenReturn("oss");
        assertThatThrownBy(()->store.requireCaptureAvailable("SALES_DOCUMENT_INTAKE")).hasMessageContaining("未启用");
        verifyNoInteractions(jdbc,files);
    }
    @Test void failedStorageAndInvalidSizeOrDigestNeverPublishAnOriginalReference() {
        var jdbc=mock(NamedParameterJdbcTemplate.class);var files=mock(ImmutableDocumentStore.class);var storage=mock(StorageService.class);
        when(storage.isEnabled()).thenReturn(true);when(storage.backend()).thenReturn("local");
        var current=mock(SecurityContextCurrentUser.class);UUID actor=UUID.randomUUID();when(current.requireId()).thenReturn(actor);
        var store=new AiInputOriginalStore(jdbc,files,storage,current,mock(AuditService.class),List.of());byte[] bytes={1};
        var correct=new AiJobInput("source.csv","text/csv","CSV",1,bytes,ImmutableDocumentStore.digest(bytes));
        when(files.save(anyString(),anyString(),anyString(),any())).thenThrow(new IllegalStateException("private failure details"));
        assertThatThrownBy(()->store.capture(UUID.randomUUID(),actor,"SALES_DOCUMENT_INTAKE",correct)).hasMessageContaining("识别没有提交").hasMessageNotContaining("private failure");
        assertThatThrownBy(()->store.capture(UUID.randomUUID(),actor,"SALES_DOCUMENT_INTAKE",new AiJobInput("source.csv","text/csv","CSV",2,bytes,"a".repeat(64)))).hasMessageContaining("内容与上传时不一致");
        byte[] large=new byte[15*1024*1024+1];
        assertThatThrownBy(()->store.capture(UUID.randomUUID(),actor,"SALES_DOCUMENT_INTAKE",new AiJobInput("source.csv","text/csv","CSV",large.length,large,ImmutableDocumentStore.digest(large)))).hasMessageContaining("内容与上传时不一致");
        verifyNoInteractions(jdbc);
    }
}
