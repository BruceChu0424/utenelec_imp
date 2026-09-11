package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.ResultSetExtractor;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class AttachmentDeletionProviderScopeTest {
    @Test void successfulDeletionResolvesOnlyTheSameProviderKeyAndVersion() throws Exception {
        var jdbc=new CapturingJdbc();var registry=mock(StorageProviderRegistry.class);var store=mock(StorageService.class);
        when(registry.require("internal")).thenReturn(store);
        assertThat(new AttachmentObjectOutboxProcessor(jdbc,registry,new StorageProperties(),id->{}).processNext()).isTrue();
        verify(store).delete("same-key.pdf","exact-version");
        var resolution=jdbc.updates.stream().filter(u->u.sql.contains("UPDATE attachment_reconciliation_findings")).findFirst().orElseThrow();
        assertThat(resolution.sql).contains("WHERE storage_provider = ? AND object_location = ? AND storage_key = ?")
                .contains("storage_version IS NOT DISTINCT FROM ?");
        assertThat(resolution.args).containsExactly("internal","FINAL","same-key.pdf","exact-version");
    }

    @Test void physicalDeleteFailureCannotPublishACompletionProof() throws Exception {
        var jdbc=new CapturingJdbc();var registry=mock(StorageProviderRegistry.class);var store=mock(StorageService.class);
        when(registry.require("internal")).thenReturn(store);
        doThrow(new IllegalStateException("unavailable object")).when(store).delete(anyString(),anyString());
        new AttachmentObjectOutboxProcessor(jdbc,registry,new StorageProperties(),id->{}).processNext();
        assertThat(jdbc.updates).noneMatch(update->update.sql.contains("'SUCCEEDED'")||update.sql.contains("'DELETED'")||update.sql.contains("'RESOLVED'"));
        assertThat(jdbc.updates).anyMatch(update->update.sql.contains("SET status = 'FAILED'"));
    }

    private record Update(String sql,List<Object> args) {}
    private static class CapturingJdbc extends JdbcTemplate {
        final List<Update> updates=new ArrayList<>();
        final ResultSet row=mock(ResultSet.class);
        CapturingJdbc() throws SQLException {
            when(row.next()).thenReturn(true);
            when(row.getObject("id",UUID.class)).thenReturn(UUID.randomUUID());
            when(row.getObject("attachment_id",UUID.class)).thenReturn(UUID.randomUUID());
            when(row.getString("operation")).thenReturn("DELETE_FINAL");
            when(row.getString("storage_key")).thenReturn("same-key.pdf");
            when(row.getString("storage_version")).thenReturn("exact-version");
            when(row.getString("storage_provider")).thenReturn("internal");
            when(row.getInt("attempts")).thenReturn(1);
        }
        @Override public <T> T query(String sql,ResultSetExtractor<T> extractor,Object...args) {
            try{return extractor.extractData(row);}catch(SQLException failure){throw new IllegalStateException(failure);}
        }
        @Override public int update(String sql,Object...args){updates.add(new Update(sql,Arrays.asList(args)));return 1;}
    }
}
