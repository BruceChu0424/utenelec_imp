package com.uten.imp.features.admin.serverstatus;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.serveroperations.HostOperationsClient;
import com.uten.imp.features.admin.serveroperations.HostOperationsException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.audit.AuditService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import javax.sql.DataSource;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static com.uten.imp.features.admin.serveroperations.HostOperationsClient.Operation.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ServerStorageServiceTest {
    private final HostOperationsClient host = mock(HostOperationsClient.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final DataSource dataSource = mock(DataSource.class);
    private final AuditService audit = mock(AuditService.class);
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private ServerStorageService service;
    private AuthUser actor;

    @BeforeEach void setup() {
        actor = user(Set.of("server_status:view"), false, null);
        when(current.get()).thenReturn(Optional.of(actor));
        service = new ServerStorageService(host, current, mapper, dataSource, audit);
    }
    @Test void unavailableHostStillReturnsRealHeapAndUnknownStorageAndDatabase() {
        when(host.call(eq(STORAGE_SUMMARY), anyMap(), eq(actor.getId()), any())).thenThrow(new HostOperationsException("UNAVAILABLE"));
        var result = service.summary();
        assertThat(result.capabilities().available()).isFalse();
        assertThat(result.capabilities().canCleanup()).isFalse();
        assertThat(result.capabilities().unavailableCode()).isEqualTo("HOST_HELPER_UNAVAILABLE");
        assertThat(result.capabilities().unavailableReason()).contains("可信连接").doesNotContain("当前平台不支持");
        assertThat(result.volumes()).isEmpty();
        assertThat(result.database().sizeBytes()).isNull();
        assertThat(result.uploads().count()).isNull();
        assertThat(result.process().heapUsedBytes()).isPositive();
        if (System.getProperty("os.name").startsWith("Windows")) {
            assertThat(result.process().rssBytes()).isNull();
            assertThat(result.process().detail()).contains("不提供进程常驻内存");
        }
    }
    @Test void typedProjectionDiscardsPrivateHelperFieldsAndBindsCleanupCapabilityToCurrentUser() throws Exception {
        when(host.call(eq(STORAGE_SUMMARY), anyMap(), eq(actor.getId()), any())).thenReturn(mapper.readTree("""
                {"sampledAt":"2026-10-15T18:00:00Z","status":"NORMAL","revision":"abc",
                 "capabilities":{"available":true,"canCleanup":true},"volumes":[],"categories":[],
                 "privateHostPath":"do-not-expose","secret":"not-public"}
                """));
        var result = service.summary();
        assertThat(result.capabilities().available()).isTrue();
        assertThat(result.capabilities().canCleanup()).isFalse();
        assertThat(result.capabilities().unavailableCode()).isNull();
        assertThat(mapper.writeValueAsString(result)).doesNotContain("do-not-expose", "not-public");
        assertThat(mapper.writeValueAsString(new ServerStorageView.Capabilities(false,false,"legacy")))
                .doesNotContain("unavailableCode");
    }
    @Test void invalidHelperProtocolKeepsRealDatabaseAndUploadMeasurements() throws Exception {
        var connection=mock(java.sql.Connection.class);
        var statement=mock(java.sql.PreparedStatement.class);
        var databaseRows=mock(java.sql.ResultSet.class);
        var uploadRows=mock(java.sql.ResultSet.class);
        when(dataSource.getConnection()).thenReturn(connection);
        when(connection.prepareStatement(anyString())).thenReturn(statement);
        when(statement.executeQuery()).thenReturn(databaseRows,uploadRows);
        when(databaseRows.next()).thenReturn(true);when(databaseRows.getLong(1)).thenReturn(4096L);
        when(uploadRows.next()).thenReturn(true);when(uploadRows.getLong(1)).thenReturn(3L);
        when(uploadRows.getLong(2)).thenReturn(90L);when(uploadRows.getLong(3)).thenReturn(100L);
        when(host.call(eq(STORAGE_SUMMARY),anyMap(),eq(actor.getId()),any())).thenReturn(mapper.createObjectNode());

        var result=service.summary();
        assertThat(result.capabilities().unavailableCode()).isEqualTo("HOST_RESPONSE_INVALID");
        assertThat(result.capabilities().unavailableReason()).contains("安全校验");
        assertThat(result.capabilities().canCleanup()).isFalse();
        assertThat(result.volumes()).isEmpty();assertThat(result.categories()).isEmpty();
        assertThat(result.process().heapUsedBytes()).isPositive();
        assertThat(result.database().status()).isEqualTo("NORMAL");assertThat(result.database().sizeBytes()).isEqualTo(4096L);
        assertThat(result.uploads().count()).isEqualTo(3L);assertThat(result.uploads().logicalBytes()).isEqualTo(90L);
        assertThat(result.uploads().storedBytes()).isEqualTo(100L);
    }
    @Test void helperCapabilitiesCannotForgeALocalPlatformLimitationOrLeakUnreviewedReasons() throws Exception {
        when(host.call(eq(STORAGE_SUMMARY),anyMap(),eq(actor.getId()),any())).thenReturn(mapper.readTree("""
                {"sampledAt":"2026-10-15T18:00:00Z","status":"UNKNOWN","revision":"abc",
                 "capabilities":{"available":false,"canCleanup":true,
                 "unavailableCode":"HOST_PLATFORM_UNSUPPORTED","unavailableReason":"RAW_PRIVATE_PATH"},
                 "volumes":[],"categories":[]}
                """));
        var result=service.summary();
        assertThat(result.capabilities().unavailableCode()).isEqualTo("HOST_HELPER_UNAVAILABLE");
        assertThat(result.capabilities().canCleanup()).isFalse();
        assertThat(mapper.writeValueAsString(result)).doesNotContain("RAW_PRIVATE_PATH","HOST_PLATFORM_UNSUPPORTED");
    }
    @Test void legacyUploadCategoryAndResourcesRemainSeparateTypedReadonlyProjections() throws Exception {
        when(host.call(eq(STORAGE_SUMMARY), anyMap(), eq(actor.getId()), any())).thenReturn(mapper.readTree("""
                {"sampledAt":"2026-10-15T18:00:00Z","status":"NORMAL","revision":"abc",
                 "capabilities":{"available":true,"canCleanup":true},"volumes":[],
                 "categories":[{"kind":"UPLOADS","label":"当前上传目录","status":"NORMAL","logicalBytes":3,"count":1},
                 {"kind":"LEGACY_UPLOADS","label":"兼容旧上传目录","status":"NORMAL","logicalBytes":12,"count":1,
                  "detail":"仍可能被历史业务引用，永不提供文件级清理。","privatePath":"do-not-expose"}]}
                """));
        var result=service.summary();
        assertThat(result.categories()).extracting(ServerStorageView.Category::kind)
                .containsExactly(ServerStorageView.Kind.UPLOADS,ServerStorageView.Kind.LEGACY_UPLOADS);
        assertThat(result.categories().get(1).logicalBytes()).isEqualTo(12);
        assertThat(mapper.writeValueAsString(result)).doesNotContain("do-not-expose");
        when(host.call(eq(STORAGE_LIST), anyMap(), eq(actor.getId()), any())).thenReturn(mapper.readTree("""
                {"sampledAt":"2026-10-15T18:00:00Z","revision":"abc","kind":"LEGACY_UPLOADS","total":1,
                 "items":[{"id":"opaque","kind":"LEGACY_UPLOADS","label":"legacy-original","canDelete":false,
                  "reclaimableBytes":0,"protectionReasons":["原件永不提供文件级清理。"]}]}
                """));
        var resources=service.resources(ServerStorageView.Kind.LEGACY_UPLOADS,null,50);
        assertThat(resources.items()).singleElement().satisfies(item->{
            assertThat(item.canDelete()).isFalse();assertThat(item.reclaimableBytes()).isZero();
            assertThat(item.protectionReasons()).contains("原件永不提供文件级清理。");
        });
        verify(host).call(eq(STORAGE_LIST),eq(Map.of("kind","LEGACY_UPLOADS","limit",50)),eq(actor.getId()),any());
    }
    @Test void monitorCannotPreviewAndVisitorCannotReadEvenWithGrant() {
        assertThatThrownBy(() -> service.preview(new ServerStorageView.PreviewRequest(List.of("a".repeat(64)))))
                .isInstanceOf(ApiException.class);
        when(current.get()).thenReturn(Optional.of(AuthUser.visitor(UUID.randomUUID(), "visitor", "V", Set.of("server:cleanup"))));
        assertThatThrownBy(service::summary).isInstanceOf(ApiException.class);
        verifyNoInteractions(host);
    }
    @Test void impersonatedAndForcedPasswordAccountsCannotMutate() {
        for (AuthUser prohibited : List.of(user(Set.of("server:cleanup"), false, UUID.randomUUID()),
                new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "first", Set.of("server:cleanup"), true, true, false))) {
            when(current.get()).thenReturn(Optional.of(prohibited));
            assertThatThrownBy(() -> service.preview(new ServerStorageView.PreviewRequest(List.of("a".repeat(64)))))
                    .isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(host);
    }
    @Test void cleanupRequestUsesAuthenticatedActorAndSameDurableRequestIdentifier() throws Exception {
        actor = user(Set.of("server:cleanup"), false, null);
        when(current.get()).thenReturn(Optional.of(actor));
        UUID preview = UUID.randomUUID(), request = UUID.randomUUID();
        when(host.call(eq(STORAGE_DELETE), anyMap(), eq(actor.getId()), eq(request)))
                .thenReturn(mapper.valueToTree(Map.of("requestId", request, "status", "SUCCEEDED", "deletedCount", 1, "reclaimedBytes", 4096, "detail", "完成")));
        assertThat(service.delete(new ServerStorageView.DeleteRequest(preview, request)).requestId()).isEqualTo(request);
        verify(host).call(STORAGE_DELETE, Map.of("previewId", preview.toString(), "requestId", request.toString()), actor.getId(), request);
        verify(audit).logExplicit(actor.getId(), actor.getLoginAccount(), "server_cleanup", "server_operations", request.toString(), "SUCCEEDED");
    }
    @Test void invalidResourceIdsAndPageLimitsNeverReachRootHelper() {
        actor = user(Set.of("server:cleanup"), false, null);
        when(current.get()).thenReturn(Optional.of(actor));
        assertThatThrownBy(() -> service.preview(new ServerStorageView.PreviewRequest(List.of("../private"))))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.preview(new ServerStorageView.PreviewRequest(List.of("a".repeat(64), "a".repeat(64)))))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.resources(ServerStorageView.Kind.UPLOADS, null, 101)).isInstanceOf(ApiException.class);
        verifyNoInteractions(host);
    }
    @Test void malformedHelperPageDoesNotBecomeAnEmptyHealthyList() throws Exception {
        when(host.call(eq(STORAGE_LIST), anyMap(), eq(actor.getId()), any())).thenReturn(mapper.readTree("{}"));
        assertThatThrownBy(() -> service.resources(ServerStorageView.Kind.PAIRED_BACKUPS, null, 50))
                .isInstanceOf(ApiException.class);
    }
    @Test void malformedCleanupAcknowledgementRemainsUncertainWhileReceiptReadsNeverClaimAMutation() {
        actor=user(Set.of("server:cleanup"),false,null);
        when(current.get()).thenReturn(Optional.of(actor));
        UUID request=UUID.randomUUID(),preview=UUID.randomUUID();
        var malformed=mapper.createObjectNode().put("requestId",request.toString()).put("status","SUCCEEDED")
                .put("deletedCount",1).put("reclaimedBytes",1024);
        malformed.putObject("detail").put("raw","PRIVATE_HELPER_DETAIL");
        when(host.call(any(),anyMap(),eq(actor.getId()),eq(request))).thenReturn(malformed);
        var mutation=catchThrowableOfType(ApiException.class,()->service.delete(new ServerStorageView.DeleteRequest(preview,request)));
        assertThat(mutation.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.SERVER_OPERATION_OUTCOME_UNCERTAIN);
        var read=catchThrowableOfType(ApiException.class,()->service.result(request));
        assertThat(read.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.SERVER_OPERATIONS_UNAVAILABLE);
        assertThat(mutation.getMessage()).doesNotContain("PRIVATE_HELPER_DETAIL");
        assertThat(read.getMessage()).doesNotContain("PRIVATE_HELPER_DETAIL");
        verifyNoInteractions(audit);
    }
    @Test void readOnlyReceiptPollingUsesSameOwnerAndNeverCallsDelete() throws Exception {
        actor = user(Set.of("server:cleanup"), false, null);
        when(current.get()).thenReturn(Optional.of(actor));
        UUID request = UUID.randomUUID();
        when(host.call(eq(STORAGE_RESULT), anyMap(), eq(actor.getId()), eq(request)))
                .thenReturn(mapper.valueToTree(Map.of("requestId", request, "status", "RUNNING", "deletedCount", 0, "reclaimedBytes", 0, "detail", "执行中")));
        assertThat(service.result(request).status()).isEqualTo("RUNNING");
        verify(host).call(STORAGE_RESULT, Map.of("requestId", request.toString()), actor.getId(), request);
        verify(host, never()).call(eq(STORAGE_DELETE), anyMap(), any(), any());
        verifyNoInteractions(audit);
    }
    private static AuthUser user(Set<String> permissions, boolean superAdmin, UUID impersonatedBy) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "ops-test", permissions, false, true, superAdmin, false, impersonatedBy);
    }
}
