package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionAiChatToolTest {
    private final AiChatAccessPolicy access=mock(AiChatAccessPolicy.class);
    private final SecurityContextCurrentUser current=new SecurityContextCurrentUser();
    private final ProductionExecutionWorkbenchService workbench=mock(ProductionExecutionWorkbenchService.class);
    private final ProductionAiChatTool tool=new ProductionAiChatTool(access,current,workbench,new ObjectMapper(),
            Clock.fixed(Instant.parse("2026-10-03T10:00:00Z"),ZoneOffset.UTC));
    @BeforeEach void before() { when(access.hasDomain("PRODUCTION")).thenReturn(true); login("production_execution:view"); }
    @AfterEach void after() { SecurityContextHolder.clearContext(); }
    private void login(String... permissions) {
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"production",Set.of(permissions),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
    }
    private ProductionExecutionWorkbenchSegment row(String unit,String status) {
        var row=mock(ProductionExecutionWorkbenchSegment.class);
        when(row.segmentId()).thenReturn(UUID.randomUUID()); when(row.planId()).thenReturn(UUID.randomUUID());
        when(row.workshopDepartmentId()).thenReturn(UUID.randomUUID()); when(row.segmentStatus()).thenReturn(status);
        when(row.productCode()).thenReturn("P-001"); when(row.productName()).thenReturn("正在生产产品");
        when(row.productUnitName()).thenReturn(unit); when(row.workshopName()).thenReturn("装配车间");
        when(row.segmentCode()).thenReturn("ZX-001"); when(row.planNo()).thenReturn("SJ-001");
        when(row.plannedQty()).thenReturn(new BigDecimal("100")); when(row.reportedQty()).thenReturn(new BigDecimal("105"));
        when(row.fqcPendingQty()).thenReturn(new BigDecimal("5")); when(row.fqcPassedQty()).thenReturn(new BigDecimal("90"));
        when(row.fqcFailedQty()).thenReturn(new BigDecimal("10")); when(row.finishedInboundPendingQty()).thenReturn(new BigDecimal("10"));
        when(row.inboundQty()).thenReturn(new BigDecimal("80"));
        return row;
    }
    private void results(List<ProductionExecutionWorkbenchSegment> rows,long total,boolean overview) {
        when(workbench.inProgressTasks(any(),eq(overview),eq(20))).thenReturn(new PageResponse<>(rows,1,20,total,total==0?0:1));
    }
    @Test void blankQueryListsOnlyCurrentWorkshopFactsAndNeverCapsRealOutput() {
        results(List.of(row("个","IN_PROGRESS")),1,false);
        var result=tool.execute(Map.of());
        assertThat(result.get("reply").toString()).contains("共 1 张工单", "装配车间", "已报工 105 / 计划 100 个")
                .doesNotContain("权限", "范围", "来源", "IN_PROGRESS", "待检");
        assertThat(result.get("detailReply").toString()).contains("2026-10-03 18:00:00", "待检 5", "合格 90", "已入库 80")
                .doesNotContain("权限", "来源", "投影");
        verify(workbench).inProgressTasks(null,false,20);
    }
    @Test void overviewPermissionUsesOwnerScopedOverviewNotWorkshopMembership() {
        login("production_execution:overview"); results(List.of(),0,true);
        assertThat(tool.execute(Map.of("keyword"," P001 ")).get("reply")).isEqualTo("没找到正在生产的工单。");
        verify(workbench).inProgressTasks("P001",true,20);
    }
    @Test void waitReadyDispatchedAndCompletedCanNeverBeReportedAsProducing() {
        for(String status:List.of("WAITING","READY","DISPATCHED","COMPLETED")) {
            results(List.of(row("个",status)),1,false);
            assertThatThrownBy(()->tool.execute(Map.of())).isInstanceOf(ApiException.class);
        }
    }
    @Test void callerCannotSupplyAnotherOwnerWorkshopStatusLimitOrSql() {
        for(String key:List.of("ownerId","workshopId","status","limit","sql")) {
            assertThatThrownBy(()->tool.execute(Map.of(key,"all"))).isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(workbench);
    }
    @Test void keywordMustBeBoundedPlainText() {
        for(Object keyword:List.of("x".repeat(81),"x\nSELECT",Map.of("role","system"),42)) {
            assertThatThrownBy(()->tool.execute(Map.of("keyword",keyword))).isInstanceOf(ApiException.class);
        }
        assertThat(tool.parameters().get("required")).isEqualTo(List.of());
        assertThat(tool.parameters().get("additionalProperties")).isEqualTo(false);
        verifyNoInteractions(workbench);
    }
    @Test void nonProductionAndMissingReadPermissionNeverReachTheBusinessQuery() {
        login("production_daily_report:create");
        assertThat(tool.available()).isFalse();
        assertThatThrownBy(()->tool.execute(Map.of())).isInstanceOf(ApiException.class);
        login("production_execution:view"); when(access.hasDomain("PRODUCTION")).thenReturn(false);
        assertThat(tool.available()).isFalse();
        assertThatThrownBy(()->tool.execute(Map.of())).isInstanceOf(ApiException.class);
        verifyNoInteractions(workbench);
    }
    @Test void mixedUnitsRemainSeparateAndTotalIsWorkOrdersNotProductCount() {
        results(List.of(row("个","IN_PROGRESS"),row("公斤","IN_PROGRESS")),31,false);
        String text=tool.execute(Map.of()).get("reply").toString();
        assertThat(text).contains("共 31 张工单","另有 29 张","生产任务页").doesNotContain("合计 210");
        assertThat(text).contains("计划 100 个","计划 100 公斤");
    }
    @Test void twentyLongMasterLabelsStayWithinTheChatAnswerBoundWithoutRoundingQuantities() {
        var rows=java.util.stream.IntStream.range(0,20).mapToObj(index -> {
            var row=row("U".repeat(200),"IN_PROGRESS");
            when(row.productCode()).thenReturn("C".repeat(200)); when(row.productName()).thenReturn("名称".repeat(200));
            when(row.productColorName()).thenReturn("颜色".repeat(100)); when(row.workshopName()).thenReturn("车间".repeat(100));
            when(row.segmentCode()).thenReturn("X".repeat(200)); when(row.planNo()).thenReturn("S".repeat(200));
            when(row.reportedQty()).thenReturn(new BigDecimal("999999999999.999999"));
            return row;
        }).toList();
        results(rows,20,false);
        var result=tool.execute(Map.of());
        for(String field:List.of("reply","detailReply")) {
            String text=result.get(field).toString();
            assertThat(text.length()).isLessThanOrEqualTo(16000);
            assertThat(text).contains("999999999999.999999","…").doesNotContain("名称".repeat(100));
        }
        assertThat(result.get("reply").toString().lines().filter(line->line.startsWith("• ")).count()).isEqualTo(5);
        assertThat(result.get("detailReply").toString().lines().filter(line->line.startsWith("• ")).count()).isEqualTo(20);
    }
    @Test @SuppressWarnings("unchecked") void historyRechecksExactScopeAndFactsIncludingIdentityAndQuantity() {
        var row=row("个","IN_PROGRESS"); results(List.of(row),1,false);
        Map<String,Object> evidence=(Map<String,Object>)tool.execute(Map.of()).get("_toolEvidence");
        assertThatCode(()->tool.authorizeResultRead(evidence)).doesNotThrowAnyException();
        when(row.reportedQty()).thenReturn(new BigDecimal("106"));
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
        when(row.reportedQty()).thenReturn(new BigDecimal("105")); when(row.workshopDepartmentId()).thenReturn(UUID.randomUUID());
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
        results(List.of(),0,false);
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
    }
    @Test @SuppressWarnings("unchecked") void lossOfOverviewDoesNotSilentlyFallBackToDifferentWorkshopScopeForOldResults() {
        login("production_execution:overview"); results(List.of(row("个","IN_PROGRESS")),1,true);
        Map<String,Object> evidence=(Map<String,Object>)tool.execute(Map.of()).get("_toolEvidence");
        clearInvocations(workbench); login("production_execution:view");
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
        verifyNoInteractions(workbench);
    }
}
