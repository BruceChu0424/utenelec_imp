package com.uten.imp.features.workbench.badge;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AiChatAccessPolicy;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkbenchAiChatToolTest {
    private final AiChatAccessPolicy access=mock(AiChatAccessPolicy.class);
    private final WorkbenchBadgeService badges=mock(WorkbenchBadgeService.class);
    private final WorkbenchAiChatTool tool=new WorkbenchAiChatTool(access,badges,new ObjectMapper());
    @BeforeEach void before() { when(access.domains()).thenReturn(Set.of("SELF","PRODUCTION")); }
    private WorkbenchBadgeSummary summary(Map<String,WorkbenchBadgeSummary.Counts> entries,String... stale) {
        return new WorkbenchBadgeSummary(Instant.parse("2026-10-03T00:00:00Z"),entries,Map.of(),WorkbenchBadgeSummary.Counts.ZERO,Map.of(),List.of(stale),List.of());
    }
    @Test @SuppressWarnings({"rawtypes","unchecked"}) void domainsRestrictWhichSourcesAreRequestedAndExpenseIsNeverQueried() {
        when(badges.summary(anySet())).thenReturn(summary(Map.of("productionWorkshop",new WorkbenchBadgeSummary.Counts(3,2))));
        String reply=tool.execute(Map.of()).get("reply").toString();
        assertThat(reply).contains("我的车间任务","待办 3 项，进行中 2 项");
        ArgumentCaptor<Set> ids=ArgumentCaptor.forClass(Set.class); verify(badges).summary(ids.capture());
        assertThat(ids.getValue()).contains("productionWorkshop","visitorHost").doesNotContain("expenseMine","expenseFinance","financeAuditCenter","hrTaskCenter","salesDrafts");
        assertThat(tool.parameters().toString()).doesNotContain("FINANCE","ADMIN","HR");
    }
    @Test void staleEntryNeverBecomesAZeroCount() {
        when(badges.summary(anySet())).thenReturn(summary(Map.of("productionWorkshop",new WorkbenchBadgeSummary.Counts(0,0)),"productionWorkshop"));
        String reply=tool.execute(Map.of()).get("reply").toString();
        assertThat(reply).contains("暂时查不到数量").doesNotContain("待办 0 项");
    }
    @Test void foreignModuleAndOwnerOverridesNeverReachBadgeSources() {
        assertThatThrownBy(()->tool.execute(Map.of("module","FINANCE"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->tool.execute(Map.of("ownerId","someone"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->tool.execute(Map.of("module","finance; SELECT"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(badges);
    }
    @Test @SuppressWarnings("unchecked") void historyRechecksChangedCountAndVisibleEntrySet() {
        when(badges.summary(anySet())).thenReturn(summary(Map.of("productionWorkshop",new WorkbenchBadgeSummary.Counts(3,2))));
        var evidence=(Map<String,Object>)tool.execute(Map.of()).get("_toolEvidence");
        tool.authorizeResultRead(evidence);
        when(badges.summary(anySet())).thenReturn(summary(Map.of("productionWorkshop",new WorkbenchBadgeSummary.Counts(4,2))));
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
        when(badges.summary(anySet())).thenReturn(summary(Map.of()));
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
    }
    @Test void unexpectedCrossModuleSourceOutputIsRejectedInsteadOfDisplayed() {
        when(badges.summary(anySet())).thenReturn(summary(Map.of("financeDrafts",new WorkbenchBadgeSummary.Counts(91,2))));
        assertThatThrownBy(()->tool.execute(Map.of())).isInstanceOf(ApiException.class);
    }
    @Test @SuppressWarnings("unchecked") void conciseReplyPrioritizesActionableEntriesWithoutWeakeningHiddenCountEvidence() {
        var rows=new java.util.LinkedHashMap<String,WorkbenchBadgeSummary.Counts>();
        rows.put("productionSchedule",new WorkbenchBadgeSummary.Counts(1,0));
        rows.put("productionRateApprovals",new WorkbenchBadgeSummary.Counts(6,0));
        rows.put("productionMaterialIncrementApprovals",new WorkbenchBadgeSummary.Counts(5,0));
        rows.put("productionPlanningUrges",new WorkbenchBadgeSummary.Counts(4,0));
        rows.put("productionWorkshop",new WorkbenchBadgeSummary.Counts(3,2));
        rows.put("productionBatches",new WorkbenchBadgeSummary.Counts(0,7));
        rows.put("productionDrafts",new WorkbenchBadgeSummary.Counts(0,0));
        when(badges.summary(anySet())).thenReturn(summary(rows));
        var result=tool.execute(Map.of());
        String reply=result.get("reply").toString(),detail=result.get("detailReply").toString();
        assertThat(reply.lines().filter(line->line.startsWith("• ")).count()).isEqualTo(5);
        assertThat(reply).contains("另有 1 项").doesNotContain("生产批次","生产单据草稿","待办 0 项","来源","权限","规则");
        assertThat(detail).contains("生产批次：进行中 7 项").doesNotContain("生产单据草稿","来源","权限");
        var evidence=(Map<String,Object>)result.get("_toolEvidence");
        tool.authorizeResultRead(evidence);
        rows.put("productionDrafts",new WorkbenchBadgeSummary.Counts(1,0));
        when(badges.summary(anySet())).thenReturn(summary(rows));
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
    }
}
