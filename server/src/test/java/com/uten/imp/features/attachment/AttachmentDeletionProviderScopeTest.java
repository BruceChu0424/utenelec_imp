package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.ResultSetExtractor;
import org.springframework.transaction.PlatformTransactionManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class AttachmentDeletionProviderScopeTest {
    @Test void finalDeletionIntentRetainsOriginalAndReportsItsRealNonDestructiveOutcome() throws Exception {
        var jdbc=new CapturingJdbc();var registry=mock(StorageProviderRegistry.class);var store=mock(StorageService.class);
        when(registry.require("internal")).thenReturn(store);
        assertThat(new AttachmentObjectOutboxProcessor(jdbc,registry,new StorageProperties(),id->{},mock(PlatformTransactionManager.class)).processNext()).isTrue();
        verifyNoInteractions(registry,store);
        assertThat(jdbc.updates).anyMatch(update->update.sql.contains("status='RETAINED_HISTORY'"));
        assertThat(jdbc.updates).noneMatch(update->update.sql.contains("'SUCCEEDED'")||update.sql.contains("'DELETED'")||update.sql.contains("'RESOLVED'"));
        var retention=jdbc.updates.stream().filter(u->u.sql.contains("UPDATE attachment_reconciliation_findings")).findFirst().orElseThrow();
        assertThat(retention.sql).contains("finding_state='IGNORED'","storage_provider=?","storage_version IS NOT DISTINCT FROM ?");
        assertThat(retention.args).containsExactly("internal","same-key.pdf","exact-version");
    }

    @Test void staleFinalIntentCannotTouchTheNewerClaimOrItsAttachmentHistory() throws Exception {
        var jdbc=new CapturingJdbc(){@Override public int update(String sql,Object...args){updates.add(new Update(sql,Arrays.asList(args)));return 0;}};
        var registry=mock(StorageProviderRegistry.class);
        new AttachmentObjectOutboxProcessor(jdbc,registry,new StorageProperties(),id->{},mock(PlatformTransactionManager.class)).processNext();
        assertThat(jdbc.updates).hasSize(1);
        assertThat(jdbc.updates.getFirst().sql).contains("attempts=?").contains("RETAINED_HISTORY");
        verifyNoInteractions(registry);
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
