package com.uten.imp.features.ai.usage;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ai_user_limits(ADR-164) 的保存与读取: 首建/CAS 乐观锁/量级校验, 以及提交闸的停用文案。
 *
 * <p>照 {@code AiProviderServiceTest} 的先例直接 mock {@link NamedParameterJdbcTemplate}: find 走
 * 真实 RowMapper + 模拟 ResultSet(覆盖空限额列的 wasNull 映射), save 的 INSERT/UPDATE 语义用
 * 内存行模拟 ON CONFLICT DO NOTHING 与 row_version 比较。
 */
class AiUserLimitsServiceTest {

    private final Map<UUID, AiUserLimitsService.Limits> rows = new HashMap<>();
    private NamedParameterJdbcTemplate jdbc;
    private AuditService audit;
    private AiUserLimitsService service;
    private UUID userId;
    private UUID actor;

    @BeforeEach
    void setUp() {
        rows.clear();
        jdbc = mock(NamedParameterJdbcTemplate.class);
        audit = mock(AuditService.class);
        service = new AiUserLimitsService(jdbc, audit);
        userId = UUID.randomUUID();
        actor = UUID.randomUUID();
        stubFind();
    }

    /** find 的 SQL 点查按 userId 命中内存行, 并真实执行行映射(含空列)。 */
    @SuppressWarnings({"unchecked", "rawtypes"})
    private void stubFind() {
        when(jdbc.query(anyString(), any(MapSqlParameterSource.class), any(RowMapper.class)))
                .thenAnswer(invocation -> {
                    RowMapper mapper = invocation.getArgument(2);
                    UUID target = ((MapSqlParameterSource) invocation.getArgument(1)).getValue("userId") == null
                            ? null : (UUID) ((MapSqlParameterSource) invocation.getArgument(1)).getValue("userId");
                    AiUserLimitsService.Limits row = target == null ? null : rows.get(target);
                    return row == null ? List.of() : List.of(mapper.mapRow(resultSet(row), 0));
                });
    }

    /** save 的两条写语句: INSERT 撞主键按 ON CONFLICT DO NOTHING 返回 0; UPDATE 按 row_version CAS。 */
    private void stubUpdate() {
        when(jdbc.update(anyString(), any(MapSqlParameterSource.class))).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            MapSqlParameterSource params = invocation.getArgument(1);
            UUID target = (UUID) params.getValue("userId");
            if (sql.contains("INSERT INTO")) {
                if (rows.containsKey(target)) {
                    return 0;
                }
                rows.put(target, row(target, params, 0L));
                return 1;
            }
            AiUserLimitsService.Limits current = rows.get(target);
            long version = params.getValue("version") == null ? -1L : ((Number) params.getValue("version")).longValue();
            if (current == null || current.rowVersion() != version) {
                return 0;
            }
            rows.put(target, row(target, params, version + 1));
            return 1;
        });
    }

    /** save 前置的 users 存在性点查(按 SQL 区分于 countDisabled 的 ai_user_limits 计数)。 */
    private void stubUserExists() {
        when(jdbc.queryForObject(contains("FROM users"), any(MapSqlParameterSource.class), eq(Integer.class)))
                .thenReturn(1);
    }

    private static AiUserLimitsService.Limits row(UUID target, MapSqlParameterSource params, long version) {
        return new AiUserLimitsService.Limits(target, (Boolean) params.getValue("disabled"),
                (Long) params.getValue("tokenLimit"), (Integer) params.getValue("jobLimit"), version);
    }

    /** 行映射读到的列: 空限额列经 getLong/getInt + wasNull 变 null。 */
    private static ResultSet resultSet(AiUserLimitsService.Limits row) throws SQLException {
        ResultSet rs = mock(ResultSet.class);
        when(rs.getObject("user_id", UUID.class)).thenReturn(row.userId());
        when(rs.getBoolean("disabled")).thenReturn(row.disabled());
        when(rs.getLong("daily_token_limit"))
                .thenReturn(row.dailyTokenLimit() == null ? 0L : row.dailyTokenLimit());
        when(rs.getInt("daily_job_limit")).thenReturn(row.dailyJobLimit() == null ? 0 : row.dailyJobLimit());
        when(rs.getLong("row_version")).thenReturn(row.rowVersion());
        when(rs.wasNull()).thenReturn(row.dailyTokenLimit() == null, row.dailyJobLimit() == null);
        return rs;
    }

    @Test
    void firstCreateInsertsWithoutCasAndAuditsTheSavedRow() {
        stubUpdate();
        stubUserExists();

        AiUserLimitsService.Limits saved = service.save(userId, true, 500_000L, 20, -1L, actor);

        assertThat(saved.disabled()).isTrue();
        assertThat(saved.dailyTokenLimit()).isEqualTo(500_000L);
        assertThat(saved.dailyJobLimit()).isEqualTo(20);
        assertThat(saved.rowVersion()).isZero();
        ArgumentCaptor<Map<String, Object>> change = ArgumentCaptor.captor();
        verify(audit).logCommittedChange(eq(actor), eq(null), eq("update_ai_user_limits"), eq("ai_user_limits"),
                eq(userId.toString()), eq("停用账号 AI 使用"), change.capture());
        assertThat(change.getValue())
                .containsEntry("disabled", true)
                .containsEntry("dailyTokenLimit", 500_000L)
                .containsEntry("dailyJobLimit", 20)
                .containsEntry("rowVersion", 0L);
    }

    @Test
    void savingOverAnExistingRowRequiresTheCurrentVersionAndBumpsIt() {
        stubUpdate();
        stubUserExists();
        rows.put(userId, new AiUserLimitsService.Limits(userId, false, 100L, 5, 3));

        AiUserLimitsService.Limits saved = service.save(userId, false, 200L, 6, 3L, actor);

        assertThat(saved.dailyTokenLimit()).isEqualTo(200L);
        assertThat(saved.dailyJobLimit()).isEqualTo(6);
        assertThat(saved.rowVersion()).isEqualTo(4L);
        verify(audit).logCommittedChange(eq(actor), any(), eq("update_ai_user_limits"), eq("ai_user_limits"),
                eq(userId.toString()), eq("保存账号 AI 限额"), any());
    }

    @Test
    void aStaleRowVersionFailsWithConflictInsteadOfOverwriting() {
        stubUpdate();
        stubUserExists();
        rows.put(userId, new AiUserLimitsService.Limits(userId, false, 100L, 5, 3));

        assertThatThrownBy(() -> service.save(userId, true, null, null, 2L, actor))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("刷新");
                });
        assertThat(rows.get(userId).disabled()).isFalse();
        assertThat(rows.get(userId).rowVersion()).isEqualTo(3L);
        verify(audit, never()).logCommittedChange(any(), any(), any(), any(), any(), any(), any());
    }

    @Test
    void magnitudeMistakesAreRejectedBeforeAnyWrite() {
        assertThatThrownBy(() -> service.save(userId, false, 1_000_000_000_000L + 1, null, -1L, actor))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThatThrownBy(() -> service.save(userId, false, 0L, null, -1L, actor))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThatThrownBy(() -> service.save(userId, false, null, 10_001, -1L, actor))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThatThrownBy(() -> service.save(userId, false, null, 0, -1L, actor))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThatThrownBy(() -> service.save(null, false, null, null, -1L, actor))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getMessage()).contains("缺少账号");
                });
        verify(jdbc, never()).update(anyString(), any(MapSqlParameterSource.class));

        // 上界本身合法(账号存在 + 首建成功)。
        stubUpdate();
        stubUserExists();
        assertThat(service.save(userId, false, 1_000_000_000_000L, 10_000, -1L, actor).rowVersion()).isZero();
    }

    @Test
    void savingForAMissingAccountFailsWithNotFoundBeforeAnyWrite() {
        stubUpdate();
        when(jdbc.queryForObject(contains("FROM users"), any(MapSqlParameterSource.class), eq(Integer.class)))
                .thenReturn(0);

        assertThatThrownBy(() -> service.save(userId, true, 500_000L, 20, -1L, actor))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.NOT_FOUND);
                    assertThat(error.getMessage()).contains("账号不存在");
                });
        // 不给幽灵 userId 首建出配置行。
        assertThat(rows).isEmpty();
        verify(jdbc, never()).update(anyString(), any(MapSqlParameterSource.class));
    }

    @Test
    void aDisabledRowBlocksTheAccountWithTheAdminPauseMessage() {
        rows.put(userId, new AiUserLimitsService.Limits(userId, true, null, null, 0));
        assertThatThrownBy(() -> service.requireEnabled(userId))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
                    assertThat(error.getMessage()).contains("已暂停").contains("管理员");
                });

        // 无行 / 未停用行 / 未登录上下文都不拦。
        rows.remove(userId);
        service.requireEnabled(userId);
        rows.put(userId, new AiUserLimitsService.Limits(userId, false, null, null, 0));
        service.requireEnabled(userId);
        service.requireEnabled(null);
    }

    @Test
    void lookupsFollowGlobalDefaultsWhenAbsentOrNullColumns() {
        assertThat(service.tokenLimit(null)).isEmpty();
        assertThat(service.jobLimitOverride(null)).isNull();
        UUID withoutRow = UUID.randomUUID();
        assertThat(service.tokenLimit(withoutRow)).isEmpty();
        assertThat(service.jobLimitOverride(withoutRow)).isNull();

        rows.put(userId, new AiUserLimitsService.Limits(userId, false, 1234L, 7, 9));
        assertThat(service.tokenLimit(userId)).contains(1234L);
        assertThat(service.jobLimitOverride(userId)).isEqualTo(7);

        // 行存在但两列为空: 依旧跟随全局。
        rows.put(userId, new AiUserLimitsService.Limits(userId, false, null, null, 9));
        assertThat(service.tokenLimit(userId)).isEmpty();
        assertThat(service.jobLimitOverride(userId)).isNull();
        assertThat(service.find(userId)).isPresent();
    }

    @Test
    void theDashboardKpiCountsDisabledAccounts() {
        when(jdbc.queryForObject(contains("ai_user_limits"), any(MapSqlParameterSource.class), eq(Integer.class)))
                .thenReturn(3);
        assertThat(service.countDisabled()).isEqualTo(3);
    }
}
