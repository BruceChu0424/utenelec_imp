package com.uten.imp.features.admin.workflow;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

class WorkflowReviewerEligibilitySqlContractTest {

    @Test
    void crossDepartmentGrantRequiresActiveOverride() {
        CapturingJdbcTemplate jdbc = new CapturingJdbcTemplate();
        WorkflowReviewerEligibility eligibility = new WorkflowReviewerEligibility(
                jdbc,
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class));

        assertThat(eligibility.findEligible(UUID.randomUUID())).isEmpty();
        assertThat(jdbc.capturedSql)
                .contains("po.effect = 'grant'")
                .contains("po.active = TRUE")
                // ADR-109：目录里只剩活码(停用即删除)，不再有权限停用列可过滤。
                .doesNotContain("perm.active");
    }

    private static final class CapturingJdbcTemplate extends JdbcTemplate {
        private String capturedSql;

        @Override
        public <T> List<T> query(
                String sql, RowMapper<T> rowMapper, Object... args) {
            capturedSql = sql;
            return List.of();
        }
    }
}
