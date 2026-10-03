package com.uten.imp.features.org.hrtask;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class HrTasksAiChatToolTest {
    private final AiChatAccessPolicy access=mock(AiChatAccessPolicy.class);
    private final HrTaskService tasks=mock(HrTaskService.class);
    private final HrTasksAiChatTool tool=new HrTasksAiChatTool(access,tasks,new ObjectMapper());
    private final UUID user=UUID.randomUUID(),employee=UUID.randomUUID();
    private AuthUser actor;
    @BeforeEach void before() {
        actor=actor("employee:view"); when(access.requireChat()).thenAnswer(call->actor); when(access.hasDomain("HR")).thenReturn(true);
    }
    private AuthUser actor(String... permissions) { return new AuthUser(user,employee,"hr",Set.of(permissions),false,true,false); }
    private HrTaskSummary.Item item(String name,LocalDate date) {
        return new HrTaskSummary.Item(UUID.randomUUID(),"E001",name,"生产部","PRIVATE_POSITION",date,48,
                "PRIVATE_BANK_OR_SALARY", "PRIVATE_CLAIMANT",false,null,false);
    }
    private HrTaskSummary summary(List<HrTaskSummary.Item> confirm,List<HrTaskSummary.Item> birthday) {
        return new HrTaskSummary(LocalDate.of(2026,10,3),3,confirm,List.of(),List.of(),4,
                birthday,List.of(),List.of(),List.of(),confirm.size()+birthday.size());
    }
    @Test void authorizedHrGetsRealTaskIdentityAndDateWithoutSensitiveOrUnneededFields() {
        when(tasks.summary()).thenReturn(summary(List.of(item("测试员工",LocalDate.of(2026,10,3))),List.of(item("PRIVATE_BIRTHDAY",LocalDate.of(2026,10,3)))));
        String reply=tool.execute(Map.of()).get("reply").toString();
        assertThat(reply).contains("2026-10-03","今日预计转正：1 项","E001","测试员工","生产部","其他同事已认领")
                .doesNotContain("PRIVATE_","48岁");
        assertThat(tool.parameters().toString()).doesNotContain("BIRTHDAY");
    }
    @Test void birthdayNeedsSeparatePermissionBeforeTheTaskServiceIsRead() {
        assertThatThrownBy(()->tool.execute(Map.of("category","BIRTHDAY"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(tasks);
    }
    @Test void authorizedBirthdayShowsReminderDateButNotAgeOrOtherPrivateFields() {
        actor=actor("employee:view","employee:pii:view");
        when(tasks.summary()).thenReturn(summary(List.of(),List.of(item("测试生日员工",LocalDate.of(2026,10,3)))));
        String reply=tool.execute(Map.of("category","BIRTHDAY")).get("reply").toString();
        assertThat(reply).contains("今日生日","测试生日员工","2026-10-03").doesNotContain("PRIVATE_","48岁");
        assertThat(tool.parameters().toString()).contains("BIRTHDAY");
    }
    @Test void departmentOrFunctionPermissionCannotBeSpoofedByTheQuery() {
        actor=actor("employee:edit"); assertThat(tool.available()).isFalse();
        assertThatThrownBy(()->tool.execute(Map.of())).isInstanceOf(ApiException.class);
        actor=actor("employee:view"); when(access.hasDomain("HR")).thenReturn(false);
        assertThatThrownBy(()->tool.execute(Map.of())).isInstanceOf(ApiException.class);
        verifyNoInteractions(tasks);
    }
    @Test void ownerAndSensitiveFieldArgumentsAreRejected() {
        for(String field:List.of("employeeId","salary","bankAccount","idNumber","sql"))
            assertThatThrownBy(()->tool.execute(Map.of(field,"all"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->tool.execute(Map.of("keyword","x".repeat(81)))).isInstanceOf(ApiException.class);
        verifyNoInteractions(tasks);
    }
    @Test void keywordFiltersExistingAuthorizedTasksWithoutPretendingLegacyAggregateBelongsToOnePerson() {
        when(tasks.summary()).thenReturn(summary(List.of(item("Alpha",LocalDate.of(2026,10,3)),item("Beta",LocalDate.of(2026,10,3))),List.of()));
        String reply=tool.execute(Map.of("category","CONFIRM","keyword","Alpha")).get("reply").toString();
        assertThat(reply).contains("Alpha","今日预计转正：1 项").doesNotContain("Beta","历史转正日期待补录");
    }
    @Test @SuppressWarnings("unchecked") void historyRejectsEmployeeChangesAndBirthdayPermissionRevocation() {
        actor=actor("employee:view","employee:pii:view");
        var original=item("Original",LocalDate.of(2026,10,3));
        when(tasks.summary()).thenReturn(summary(List.of(),List.of(original)));
        Map<String,Object> evidence=(Map<String,Object>)tool.execute(Map.of("category","BIRTHDAY")).get("_toolEvidence");
        tool.authorizeResultRead(evidence);
        when(tasks.summary()).thenReturn(summary(List.of(),List.of(item("Original",original.date()))));
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
        clearInvocations(tasks); actor=actor("employee:view");
        assertThatThrownBy(()->tool.authorizeResultRead(evidence)).isInstanceOf(ApiException.class);
        verifyNoInteractions(tasks);
    }
    @Test void malformedHistoricalEvidenceFailsClosedWithoutNullPointer() {
        Map<String,Object> broken=new java.util.HashMap<>(); broken.put("category",null); broken.put("keyword",""); broken.put("snapshot","x");
        assertThatThrownBy(()->tool.authorizeResultRead(broken)).isInstanceOf(ApiException.class);
        verifyNoInteractions(tasks);
    }
}
