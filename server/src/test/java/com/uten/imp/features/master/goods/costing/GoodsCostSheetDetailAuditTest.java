package com.uten.imp.features.master.goods.costing;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.AuthorityUtils;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real method-security boundary; successful detail reads delegate exactly once to the shared deduplicating recorder. */
class GoodsCostSheetDetailAuditTest {
    private AnnotationConfigApplicationContext context;
    private GoodsCostSheetController controller;
    private GoodsCostSheetService service;
    private AuditDetailViewRecorder recorder;

    @BeforeEach
    void setUp() {
        context = new AnnotationConfigApplicationContext(MethodSecurityConfiguration.class);
        controller = context.getBean(GoodsCostSheetController.class);
        service = context.getBean(GoodsCostSheetService.class);
        recorder = context.getBean(AuditDetailViewRecorder.class);
        login("goods:view", "goods:cost:view");
    }

    @AfterEach
    void close() {
        SecurityContextHolder.clearContext();
        context.close();
    }

    @Test
    void sheetReadRecordsOneSafeBusinessReferenceAfterSuccessfulScopeCheck() {
        UUID id = UUID.randomUUID();
        Sheet sheet = mock(Sheet.class);
        when(sheet.id()).thenReturn(id);
        when(sheet.sheetNo()).thenReturn("CB-000001");
        when(service.get(id)).thenReturn(sheet);
        assertSame(sheet, controller.get(id));
        var ordered = inOrder(service, recorder);
        ordered.verify(service).get(id);
        ordered.verify(recorder).record("view_goods_cost_sheet_detail", "goods_cost_sheets", id,
                "CB-000001", null, "货品成本单");
        verifyNoMoreInteractions(recorder);
        verify(sheet, never()).input();
        verify(sheet, never()).calculation();
    }

    @Test
    void snapshotReadRecordsItsOwnImmutableIdentityOnceWithoutSerializingCosts() {
        UUID id = UUID.randomUUID();
        Snapshot snapshot = mock(Snapshot.class);
        when(snapshot.id()).thenReturn(id);
        when(snapshot.sheetNo()).thenReturn("CB-000002");
        when(service.readSnapshot(id)).thenReturn(snapshot);
        assertSame(snapshot, controller.readSnapshot(id));
        var ordered = inOrder(service, recorder);
        ordered.verify(service).readSnapshot(id);
        ordered.verify(recorder).record("view_goods_cost_snapshot_detail", "goods_cost_snapshots", id,
                "CB-000002", null, "货品成本版本");
        verifyNoMoreInteractions(recorder);
        verify(snapshot, never()).input();
        verify(snapshot, never()).calculation();
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "goods:view", "goods:cost:view"})
    void missingEitherPermissionCannotReadOrWriteSuccessfulViewAudit(String authority) {
        login(authority.isEmpty() ? new String[0] : new String[]{authority});
        assertThrows(AccessDeniedException.class, () -> controller.get(UUID.randomUUID()));
        assertThrows(AccessDeniedException.class, () -> controller.readSnapshot(UUID.randomUUID()));
        verifyNoInteractions(service, recorder);
    }

    @ParameterizedTest
    @EnumSource(value = ErrorCode.class, names = {"FORBIDDEN", "NOT_FOUND"})
    void deniedOrMissingBusinessObjectNeverRecordsASuccessfulView(ErrorCode code) {
        UUID sheetId = UUID.randomUUID(), snapshotId = UUID.randomUUID();
        ApiException rejected = new ApiException(code, "成本资料不存在或无权查看");
        when(service.get(sheetId)).thenThrow(rejected);
        when(service.readSnapshot(snapshotId)).thenThrow(rejected);
        assertSame(rejected, assertThrows(ApiException.class, () -> controller.get(sheetId)));
        assertSame(rejected, assertThrows(ApiException.class, () -> controller.readSnapshot(snapshotId)));
        verifyNoInteractions(recorder);
    }

    @Test
    void listAndVersionListDoNotFabricateDetailViewRecords() {
        UUID goods = UUID.randomUUID(), sheet = UUID.randomUUID();
        when(service.list(goods)).thenReturn(List.of());
        when(service.snapshots(sheet)).thenReturn(List.of());
        assertTrue(controller.list(goods).isEmpty());
        assertTrue(controller.snapshots(sheet).isEmpty());
        verifyNoInteractions(recorder);
    }

    private static void login(String... authorities) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "cost-viewer", "unused", AuthorityUtils.createAuthorityList(authorities)));
    }

    @Configuration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class MethodSecurityConfiguration {
        @Bean GoodsCostSheetService service() { return mock(GoodsCostSheetService.class); }
        @Bean GoodsActualCostSnapshotService actual() { return mock(GoodsActualCostSnapshotService.class); }
        @Bean AuditDetailViewRecorder recorder() { return mock(AuditDetailViewRecorder.class); }
        @Bean GoodsCostSheetController controller(GoodsCostSheetService service,
                GoodsActualCostSnapshotService actual, AuditDetailViewRecorder recorder) {
            return new GoodsCostSheetController(service, actual, recorder,
                    mock(com.uten.imp.application.port.GoodsProductionOutputQueryPort.class));
        }
    }
}
