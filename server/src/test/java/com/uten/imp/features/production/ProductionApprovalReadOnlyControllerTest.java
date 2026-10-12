package com.uten.imp.features.production;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportController;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.plan.ProductionPlanController;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.authorization.method.AuthorizationManagerBeforeMethodInterceptor;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class ProductionApprovalReadOnlyControllerTest {
    private ProductionPlanService plans;
    private ProductionDailyReportService reports;
    private MockMvc http;

    @AfterEach void clearAuthentication() { SecurityContextHolder.clearContext(); }

    @BeforeEach void setUp() {
        plans = mock(ProductionPlanService.class);
        reports = mock(ProductionDailyReportService.class);
        http = MockMvcBuilders.standaloneSetup(
                new ProductionPlanController(plans, mock(AuditDetailViewRecorder.class)),
                new ProductionDailyReportController(reports, mock(ReportablePlanLineQueryService.class),
                        mock(AuditDetailViewRecorder.class))).build();
    }

    @Test void oldReviewEditorCannotReadOrWriteThroughItsRemovedEndpoints() throws Exception {
        for (String family : new String[]{"plans", "daily-reports"}) {
            String path = "/api/production/" + family + "/" + UUID.randomUUID() + "/draft-review";
            http.perform(get(path)).andExpect(status().isNotFound());
            http.perform(put(path).contentType(MediaType.APPLICATION_JSON)
                    .content("{\"expectedSnapshot\":\"old\",\"approveNow\":true,\"document\":{\"remark\":\"changed\"}}"))
                    .andExpect(status().isNotFound());
        }
        verifyNoInteractions(plans, reports);
    }

    @Test void normalApprovalAndReadonlyMaterialReviewRemainAvailable() throws Exception {
        UUID plan = UUID.randomUUID();
        UUID report = UUID.randomUUID();
        http.perform(post("/api/production/plans/" + plan + "/approve"))
                .andExpect(status().isOk());
        http.perform(get("/api/production/daily-reports/" + report + "/material-review"))
                .andExpect(status().isOk());
        verify(plans).approve(plan);
        verify(reports).materialReview(report);
    }

    @Test void reviewPermissionCannotUpdateDraftsOrUseTheirExtensionFieldSaveLock() {
        SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(
                "reviewer", "unused", List.of(new SimpleGrantedAuthority("production_plan:approve"),
                        new SimpleGrantedAuthority("production_plan:view"),
                        new SimpleGrantedAuthority("production_daily_report:approve"),
                        new SimpleGrantedAuthority("production_daily_report:view"))));
        ProductionPlanService securedPlans = secured(plans);
        ProductionDailyReportService securedReports = secured(reports);
        UUID id = UUID.randomUUID();
        PlanSaveRequest plan = new PlanSaveRequest();
        DailyReportSaveRequest report = new DailyReportSaveRequest();
        assertThatThrownBy(() -> securedPlans.update(id, plan)).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> securedPlans.lockPlatformColumnSave(id, plan)).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> securedReports.update(id, report)).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(plans, reports);
    }

    @SuppressWarnings("unchecked")
    private static <T> T secured(T target) {
        ProxyFactory factory = new ProxyFactory(target);
        factory.setProxyTargetClass(true);
        factory.addAdvisor(AuthorizationManagerBeforeMethodInterceptor.preAuthorize());
        return (T) factory.getProxy();
    }
}
