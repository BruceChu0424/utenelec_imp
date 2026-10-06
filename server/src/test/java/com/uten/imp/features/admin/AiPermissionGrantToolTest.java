package com.uten.imp.features.admin;

import com.uten.imp.application.port.AiChatActionProposalPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AiPermissionGrantToolTest {
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final PermissionRepository permissions = mock(PermissionRepository.class);
    private final UserAccountRepository accounts = mock(UserAccountRepository.class);
    private final UUID actorId = UUID.randomUUID(), targetId = UUID.randomUUID(), permissionId = UUID.randomUUID();
    private final AiChatActionProposalPort proposals = mock(AiChatActionProposalPort.class);
    private AiPermissionGrantTool tool;
    private int candidateCount = 1;

    @BeforeEach void setup() throws Exception {
        tool = new AiPermissionGrantTool(current, access, jdbc, permissions, accounts, proposals);
        when(proposals.propose(any())).thenReturn(Map.of("type", "CONFIRM_ACTION", "proposalId", UUID.randomUUID().toString()));
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, UUID.randomUUID(), "admin",
                Set.of("authorization:manage", "ai:use"), false, true, true)));
        var state = mock(UserAccountRepository.AccountState.class);
        when(state.isSuperAdmin()).thenReturn(true); when(state.getStatus()).thenReturn("active");
        when(state.getAuthVersion()).thenReturn(7L); when(state.getAuthorizationEpoch()).thenReturn(4L);
        when(accounts.findAccountStateById(actorId)).thenReturn(Optional.of(state));
        doAnswer(call -> {
            RowMapper<?> mapper = call.getArgument(1);
            var result = new ArrayList<Object>();
            for (int i = 0; i < candidateCount; i++) {
                var row = mock(ResultSet.class);
                when(row.getObject("id", UUID.class)).thenReturn(i == 0 ? targetId : UUID.randomUUID());
                when(row.getLong("auth_version")).thenReturn(12L);
                when(row.getString("code")).thenReturn("E00" + (i + 1));
                when(row.getString("full_name")).thenReturn("员工" + (i + 1));
                when(row.getString("department")).thenReturn("生产部");
                result.add(mapper.mapRow(row, i));
            }
            return result;
        }).when(jdbc).query(anyString(), ArgumentMatchers.<RowMapper<Object>>any(), any(Object[].class));
        var permission = new Permission(); permission.setId(permissionId); permission.setCode("goods:view");
        permission.setName("查看货品"); permission.setDescription("可查看货品名称和规格。");
        when(permissions.findByCode("goods:view")).thenReturn(Optional.of(permission));
    }
    @Test void conciseConfirmationBecomesAOneTimeServerCardWithStepUp() {
        var response = tool.execute(Map.of("employeeKeyword", "E001", "permissionKeyword", "goods:view"));
        assertThat(response.get("reply").toString()).contains("确认", "验证身份").hasSizeLessThan(60)
                .doesNotContain("范围", "规则", "来源");
        assertThat((List<?>) response.get("actions")).hasSize(1);
        var draft = ArgumentCaptor.forClass(AiChatActionProposalPort.Draft.class);
        verify(proposals).propose(draft.capture());
        var value = draft.getValue();
        assertThat(value.actionType()).isEqualTo(AiChatActionProposalPort.PERMISSION_GRANT);
        assertThat(value.execution()).isEqualTo("SERVER");
        assertThat(value.requiresStepUp()).isTrue();
        assertThat(value.risk()).isEqualTo("HIGH");
        assertThat(value.targetType()).isEqualTo("USER");
        assertThat(value.targetRef()).isEqualTo(targetId.toString());
        assertThat(value.targetVersion()).isEqualTo(12L);
        assertThat(value.args()).containsEntry("permissionId", permissionId.toString()).containsEntry("permissionCode", "goods:view");
        assertThat(String.join(" | ", value.summaryLines())).contains("员工1(E001, 生产部)", "查看货品",
                "只增加这一项授权", "可查看货品名称和规格");
    }
    @Test void ambiguousStaffShowsFiveChoicesAndDoesNotPrepareAGrant() {
        candidateCount = 7;
        var response = tool.execute(Map.of("employeeKeyword", "员工", "permissionKeyword", "goods:view"));
        assertThat(response.get("reply").toString()).contains("E001", "E005").doesNotContain("E006", "E007");
        assertThat(response.get("detailReply").toString()).contains("E006", "E007");
        assertThat(response).doesNotContainKey("actions"); verifyNoInteractions(permissions, proposals);
    }
    @Test void onlyTheAdminsOwnGrantWordingRunsTheTool() {
        for (String asked : List.of("给 E0123 开通付款审批权限", "授予张三报价查看", "给李四加上订单查看权限", "grant Alice the quote view permission")) {
            assertThat(AiPermissionGrantTool.grantRequested(asked)).as(asked).isTrue();
        }
        for (String reading : List.of("这页说了什么", "有什么需要检查", "这条通知是谁发的", "summarize this page")) {
            assertThat(AiPermissionGrantTool.grantRequested(reading)).as(reading).isFalse();
        }
    }

    @Test void ordinaryStaffStillCannotPrepareAGrant() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, UUID.randomUUID(), "staff",
                Set.of("authorization:manage", "ai:use"), false, true, false)));
        assertThatThrownBy(() -> tool.execute(Map.of("employeeKeyword", "E001", "permissionKeyword", "goods:view")))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(jdbc, accounts, permissions, proposals);
    }
}
