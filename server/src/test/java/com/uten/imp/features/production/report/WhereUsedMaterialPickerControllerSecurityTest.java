package com.uten.imp.features.production.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

/** Real controller method-security proxy, with no server or database startup. */
class WhereUsedMaterialPickerControllerSecurityTest {
    private AnnotationConfigApplicationContext context;
    private ProductionReportController controller;
    private ProductionWhereUsedQueryService query;

    @Configuration(proxyBeanMethods = false)
    @EnableMethodSecurity
    static class SecurityConfiguration {
        @Bean ProductionWhereUsedQueryService query() { return mock(ProductionWhereUsedQueryService.class); }
        @Bean ProductionReportController controller(ProductionWhereUsedQueryService query) {
            return new ProductionReportController(mock(ProductionReportService.class), query,
                    mock(XlsxExportService.class), mock(WorkbookDownloadService.class),
                    mock(AuditService.class), mock(SecurityContextCurrentUser.class));
        }
    }

    @BeforeEach void start() {
        context = new AnnotationConfigApplicationContext(SecurityConfiguration.class);
        controller = context.getBean(ProductionReportController.class);
        query = context.getBean(ProductionWhereUsedQueryService.class);
    }

    @AfterEach void close() {
        SecurityContextHolder.clearContext();
        if (context != null) context.close();
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "goods:view", "material_category:view", "production_report:view"})
    void otherReadPermissionsCannotDiscoverPickerCategoriesMatchesOrGoods(String permission) {
        login(permission.isEmpty() ? Set.of() : Set.of(permission));
        assertThatThrownBy(controller::whereUsedMaterialCategories).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> controller.whereUsedMaterialCategoryMatches("steel"))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> controller.whereUsedMaterials("steel", "history-uncategorized", 1, 30))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> controller.whereUsedMaterials("steel", "history-uncategorized", 1, 30, true))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> controller.whereUsedMaterialCategoryMatches("steel", "history-uncategorized", true))
                .isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(query);
    }

    @Test
    void dedicatedPermissionAloneCanUseTheSharedPickerAndPreservesItsExactCriteria() {
        login(Set.of("production_where_used:view"));
        String category = UUID.randomUUID().toString();
        var tree = List.of(new WhereUsedMaterialCategory(category, "CAT", "Category", 0, null, 0, List.of()));
        var matches = List.of(category, "history-uncategorized");
        var page = new PageResponse<WhereUsedMaterialOption>(List.of(), 3, 17, 0L, 0);
        when(query.whereUsedMaterialCategories()).thenReturn(tree);
        when(query.whereUsedMaterialCategoryMatches("% literal")).thenReturn(matches);
        when(query.searchWhereUsedMaterials("% literal", category, 3, 17)).thenReturn(page);

        assertThat(controller.whereUsedMaterialCategories()).containsEntry("items", tree);
        assertThat(controller.whereUsedMaterialCategoryMatches("% literal")).containsEntry("items", matches);
        assertThat(controller.whereUsedMaterials("% literal", category, 3, 17)).isSameAs(page);
        verify(query).whereUsedMaterialCategories();
        verify(query).whereUsedMaterialCategoryMatches("% literal");
        verify(query).searchWhereUsedMaterials("% literal", category, 3, 17);
        verifyNoMoreInteractions(query);
    }

    @Test void expandedSearchUsesTheSameDedicatedPermissionAndPassesEveryScopeFlag() {
        login(Set.of("production_where_used:view"));
        var page=new PageResponse<WhereUsedMaterialOption>(List.of(),2,9,0,0);
        when(query.searchWhereUsedMaterials("steel M3","history-uncategorized",2,9,true)).thenReturn(page);
        when(query.whereUsedMaterialCategoryMatches("steel M3","history-uncategorized",true)).thenReturn(List.of("history-uncategorized"));
        assertThat(controller.whereUsedMaterials("steel M3","history-uncategorized",2,9,true)).isSameAs(page);
        assertThat(controller.whereUsedMaterialCategoryMatches("steel M3","history-uncategorized",true))
                .containsEntry("items",List.of("history-uncategorized"));
        verify(query).searchWhereUsedMaterials("steel M3","history-uncategorized",2,9,true);
        verify(query).whereUsedMaterialCategoryMatches("steel M3","history-uncategorized",true);
        verifyNoMoreInteractions(query);
    }

    private static void login(Set<String> permissions) {
        AuthUser actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "where-used-picker-test",
                permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(actor, "unused", actor.getAuthorities()));
    }
}
