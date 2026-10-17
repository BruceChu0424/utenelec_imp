package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.StorageProperties;
import java.nio.file.Path;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ServerOperationsRuntimeBindingTest {
    @TempDir Path directory;
    @Test void identityComesFromTheActualConnectionAndActiveBeanWithoutAnyCredentialOrUrl() throws Exception {
        var source=mock(DataSource.class);var connection=mock(java.sql.Connection.class);
        var statement=mock(java.sql.Statement.class);var rows=mock(java.sql.ResultSet.class);
        when(source.getConnection()).thenReturn(connection);when(connection.createStatement()).thenReturn(statement);
        when(statement.executeQuery(anyString())).thenReturn(rows);when(rows.next()).thenReturn(true);
        when(rows.getString("database")).thenReturn("actual_db");when(rows.getString("host")).thenReturn("127.0.0.1");when(rows.getInt("port")).thenReturn(5433);
        when(rows.getObject("postmaster_started_at",java.time.OffsetDateTime.class))
                .thenReturn(java.time.OffsetDateTime.parse("2026-10-15T09:20:00.123456+08:00"));
        when(rows.getString("schema")).thenReturn("public");
        var active=mock(StorageService.class);when(active.backend()).thenReturn("internal");
        var properties=new StorageProperties();properties.setProvider("disabled");properties.getInternal().setRoot(directory.toString());
        var value=new ServerOperationsRuntimeBinding(source,active,properties).capture();
        assertThat(value).containsEntry("database","actual_db").containsEntry("host","127.0.0.1").containsEntry("port",5433)
                .containsEntry("storageProvider","internal").containsEntry("mediaRoot",directory.toRealPath().toString())
                .containsEntry("legacyLocalEnabled",false).containsEntry("legacyLocalRoot",null)
                .containsEntry("postmasterStartedAt","2026-10-15T01:20:00.123456Z").hasSize(8);
        assertThat(value.keySet()).doesNotContain("password","username","url","jdbcUrl");
        verify(statement).setQueryTimeout(5);verify(rows).close();verify(statement).close();verify(connection).close();
        verify(connection,never()).getMetaData();
    }
    @Test void enabledHistoricalLocalStorageIsAlsoBoundToItsRealDirectory() throws Exception {
        var source=source();var active=mock(StorageService.class);when(active.backend()).thenReturn("local");
        var properties=new StorageProperties();properties.setLocalDir(directory.toString());properties.setLegacyLocalReadEnabled(true);
        var value=new ServerOperationsRuntimeBinding(source,active,properties).capture();
        assertThat(value.get("mediaRoot")).isEqualTo(directory.toRealPath().toString());
        assertThat(value.get("legacyLocalRoot")).isEqualTo(directory.toRealPath().toString());
        assertThat(value.get("legacyLocalEnabled")).isEqualTo(true);
    }
    @Test void disabledStorageDoesNotInventADiskRoot() throws Exception {
        var active=mock(StorageService.class);when(active.backend()).thenReturn("disabled");
        var value=new ServerOperationsRuntimeBinding(source(),active,new StorageProperties()).capture();
        assertThat(value.get("storageProvider")).isEqualTo("disabled");assertThat(value.get("mediaRoot")).isNull();
    }
    @Test void unavailableOrMissingRuntimeRootsFailBeforeAnUpdateCanBeSubmittedWithoutLeakingDiagnostics() throws Exception {
        var broken=mock(DataSource.class);when(broken.getConnection()).thenThrow(new java.sql.SQLException("jdbc:postgresql://private?password=secret"));
        var active=mock(StorageService.class);var properties=new StorageProperties();
        var failure=catchThrowableOfType(ApiException.class,()->new ServerOperationsRuntimeBinding(broken,active,properties).capture());
        assertThat(failure.getMessage()).doesNotContain("jdbc:","password","secret");assertThat(failure.getCause()).isNull();
        when(active.backend()).thenReturn("internal");properties.getInternal().setRoot(directory.resolve("missing").toString());
        assertThatThrownBy(()->new ServerOperationsRuntimeBinding(source(),active,properties).capture()).isInstanceOf(ApiException.class);
    }
    @Test void aDifferentBusinessSchemaIsRejectedRatherThanClaimingPublicMigrationsCoverIt() throws Exception {
        var active=mock(StorageService.class);when(active.backend()).thenReturn("disabled");
        assertThatThrownBy(()->new ServerOperationsRuntimeBinding(source("tenant_private"),active,new StorageProperties()).capture())
                .isInstanceOf(ApiException.class).hasMessageNotContaining("tenant_private");
    }
    private DataSource source() throws Exception { return source("public"); }
    private DataSource source(String schema) throws Exception {
        var source=mock(DataSource.class);var connection=mock(java.sql.Connection.class);var statement=mock(java.sql.Statement.class);var rows=mock(java.sql.ResultSet.class);
        when(source.getConnection()).thenReturn(connection);when(connection.createStatement()).thenReturn(statement);when(statement.executeQuery(anyString())).thenReturn(rows);
        when(rows.next()).thenReturn(true);when(rows.getString("database")).thenReturn("actual_db");when(rows.getString("host")).thenReturn("unix");when(rows.getInt("port")).thenReturn(5432);
        when(rows.getObject("postmaster_started_at",java.time.OffsetDateTime.class))
                .thenReturn(java.time.OffsetDateTime.parse("2026-10-15T01:20:00.123456Z"));
        when(rows.getString("schema")).thenReturn(schema);
        return source;
    }
}
