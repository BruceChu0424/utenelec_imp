package com.uten.imp.features.production.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.GoodsBomWhereUsedReplacementController;
import com.uten.imp.features.master.goods.GoodsBomWhereUsedReplacementService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.apache.pdfbox.Loader;
import org.junit.jupiter.api.*;
import org.springframework.context.annotation.*;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.AopTestUtils;

import java.io.ByteArrayInputStream;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Method-security proxies plus actual encrypted workbook/PDF rendering. */
class WhereUsedExportAndReplacementSecurityTest {
    AnnotationConfigApplicationContext context;
    WhereUsedExportController exports;
    GoodsBomWhereUsedReplacementController replacement;
    WhereUsedExportService source;
    GoodsBomWhereUsedReplacementService commands;
    final UUID material = UUID.randomUUID();

    @Configuration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class SecurityConfiguration {
        @Bean WhereUsedExportService source() { return mock(WhereUsedExportService.class); }
        @Bean GoodsBomWhereUsedReplacementService commands() { return mock(GoodsBomWhereUsedReplacementService.class); }
        @Bean WhereUsedExportController exports(WhereUsedExportService source) {
            var user = mock(SecurityContextCurrentUser.class);
            when(user.get()).thenReturn(Optional.empty());
            return new WhereUsedExportController(source, new XlsxExportService(), new TabularPdfExportService(),
                    new WorkbookDownloadService(), user, mock(AuditService.class));
        }
        @Bean GoodsBomWhereUsedReplacementController replacement(GoodsBomWhereUsedReplacementService commands) {
            return new GoodsBomWhereUsedReplacementController(commands);
        }
    }
    @BeforeEach void before() {
        context = new AnnotationConfigApplicationContext(SecurityConfiguration.class);
        exports = context.getBean(WhereUsedExportController.class);
        replacement = context.getBean(GoodsBomWhereUsedReplacementController.class);
        source = AopTestUtils.getUltimateTargetObject(context.getBean(WhereUsedExportService.class));
        commands = AopTestUtils.getUltimateTargetObject(context.getBean(GoodsBomWhereUsedReplacementService.class));
        when(source.document(any(), anyString(), isNull(), isNull(), isNull(), isNull())).thenReturn(
                new ExportDocument("物料反查与追溯", List.of("当前组件：M001", "操作员：server-user", "筛选来源：当前 BOM"),
                        List.of(new ExportDocument.Section("组件使用产品", List.of(new ExportColumn("name", "产品名称", "text")),
                                List.of(Map.of("name", "=HYPERLINK(\"https://example.invalid\")"))))));
    }
    @AfterEach void after() { SecurityContextHolder.clearContext(); context.close(); }

    @Test void viewOrGenericProductionExportCannotWriteOrExportRelationshipEvidence() {
        for (Set<String> permissions : List.of(Set.of("production_where_used:view"),
                Set.of("production_where_used:view", "production_report:export"), Set.of("goods:bom:edit"))) {
            login(permissions);
            assertThrows(AccessDeniedException.class, () -> exports.export(material, "all", null, null, null, null,
                    new WhereUsedExportController.Request("", "xlsx")));
            assertThrows(AccessDeniedException.class, () -> replacement.preview(
                    new GoodsBomWhereUsedReplacementService.Request(material, UUID.randomUUID(), List.of(UUID.randomUUID()))));
            assertThrows(AccessDeniedException.class, () -> replacement.commit(new GoodsBomWhereUsedReplacementService.Commit(UUID.randomUUID())));
        }
        verifyNoInteractions(source, commands);
    }

    @Test void exportAndReplacementRequireTheirIndependentCompletePermissionPairs() throws Exception {
        login(Set.of("production_where_used:view", "production_where_used:export"));
        byte[] bytes = exports.export(material, "current", null, null, null, null,
                new WhereUsedExportController.Request("test-password", "xlsx")).getBody();
        assertNotNull(bytes);
        try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(bytes), "test-password")) {
            assertEquals("说明", workbook.getSheetAt(0).getSheetName());
            assertEquals("当前组件：M001", workbook.getSheetAt(0).getRow(1).getCell(0).getStringCellValue());
            var cell = workbook.getSheetAt(1).getRow(1).getCell(0);
            assertEquals(CellType.STRING, cell.getCellType(), "data cannot become a spreadsheet formula");
            assertEquals("=HYPERLINK(\"https://example.invalid\")", cell.getStringCellValue());
        }
        assertThrows(AccessDeniedException.class, () -> replacement.commit(new GoodsBomWhereUsedReplacementService.Commit(UUID.randomUUID())));
        login(Set.of("production_where_used:view", "goods:bom:edit"));
        var request = new GoodsBomWhereUsedReplacementService.Request(material, UUID.randomUUID(), List.of(UUID.randomUUID()));
        replacement.preview(request);
        verify(commands).preview(request);
    }

    @Test void pdfUsesTheSameAuthorizedSnapshotAndPasswordProtection() throws Exception {
        login(Set.of("production_where_used:view", "production_where_used:export"));
        var response = exports.export(material, "current", null, null, null, null,
                new WhereUsedExportController.Request("test-password", "pdf"));
        assertEquals("application/pdf", response.getHeaders().getFirst("Content-Type"));
        try (var pdf = Loader.loadPDF(Objects.requireNonNull(response.getBody()), "test-password")) {
            assertTrue(pdf.isEncrypted());
            assertTrue(pdf.getNumberOfPages() >= 2);
        }
    }

    @Test void unsupportedFormatIsRejectedBeforeReadingData() {
        login(Set.of("production_where_used:view", "production_where_used:export"));
        assertThrows(ApiException.class, () -> exports.export(material, "all", null, null, null, null,
                new WhereUsedExportController.Request("", "csv")));
        verifyNoInteractions(source);
    }

    private void login(Set<String> permissions) {
        AuthUser user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader", permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }
}
