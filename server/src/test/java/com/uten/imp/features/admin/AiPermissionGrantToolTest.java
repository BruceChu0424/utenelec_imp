package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
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
    private AiPermissionProposalCodec codec;
    private AiPermissionGrantTool tool;
    private int candidateCount = 1;

    @BeforeEach void setup() throws Exception {
        var crypto = new CryptoProperties(); crypto.setHmacKey("test-only-proposal-signing-key-not-for-production-123");
        var jwt = new JwtProperties(); jwt.setIssuer("test-local");
        codec = new AiPermissionProposalCodec(new ObjectMapper(), crypto, jwt);
        tool = new AiPermissionGrantTool(current, access, jdbc, permissions, accounts, codec);
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
        }).when(jdbc).query(anyString(), any(RowMapper.class), any(Object[].class));
        var permission = new Permission(); permission.setId(permissionId); permission.setCode("goods:view");
        permission.setName("查看货品"); permission.setDescription("可查看货品名称和规格。");
        when(permissions.findByCode("goods:view")).thenReturn(Optional.of(permission));
    }
    @Test void conciseConfirmationKeepsTheExactTargetImpactAndSignedIntent() {
        var response = tool.execute(Map.of("employeeKeyword", "E001", "permissionKeyword", "goods:view"));
        assertThat(response.get("reply").toString()).contains("确认", "验证身份").hasSizeLessThan(60)
                .doesNotContain("范围", "规则", "来源");
        var action = (Map<?, ?>) ((List<?>) response.get("actions")).getFirst();
        assertThat(action.get("targetName")).isEqualTo("员工1(E001，生产部)");
        assertThat(action.get("permissionName")).isEqualTo("查看货品");
        assertThat(action.get("permissionCode")).isEqualTo("goods:view");
        assertThat(action.get("scopeSummary").toString()).contains("只增加这一项授权", "可查看货品名称和规格");
        var intent = codec.decode(action.get("proposalId").toString());
        assertThat(intent.actorId()).isEqualTo(actorId); assertThat(intent.targetId()).isEqualTo(targetId);
        assertThat(intent.permissionId()).isEqualTo(permissionId); assertThat(intent.permissionCode()).isEqualTo("goods:view");
        assertThat(intent.actorAuthVersion()).isEqualTo(7); assertThat(intent.targetAuthVersion()).isEqualTo(12);
        assertThat(intent.authorizationEpoch()).isEqualTo(4); assertThat(intent.expiresAt() - intent.issuedAt()).isEqualTo(600);
    }
    @Test void ambiguousStaffShowsFiveChoicesAndDoesNotPrepareAGrant() {
        candidateCount = 7;
        var response = tool.execute(Map.of("employeeKeyword", "员工", "permissionKeyword", "goods:view"));
        assertThat(response.get("reply").toString()).contains("E001", "E005").doesNotContain("E006", "E007");
        assertThat(response.get("detailReply").toString()).contains("E006", "E007");
        assertThat(response).doesNotContainKey("actions"); verifyNoInteractions(permissions);
    }
    @Test void ordinaryStaffStillCannotPrepareAGrant() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, UUID.randomUUID(), "staff",
                Set.of("authorization:manage", "ai:use"), false, true, false)));
        assertThatThrownBy(() -> tool.execute(Map.of("employeeKeyword", "E001", "permissionKeyword", "goods:view")))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(jdbc, accounts, permissions);
    }
}
