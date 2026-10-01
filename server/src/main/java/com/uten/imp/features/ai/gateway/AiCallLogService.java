package com.uten.imp.features.ai.gateway;

import com.uten.imp.application.port.BusinessDataResetGatePort;
import com.uten.imp.features.ai.provider.AiProviderDtos;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * AI 调用技术记录(ai_call_logs, ADR-133): 每次调用(含重试的每一次)一行, 只有用途、服务商、模型、
 * 成败、HTTP 状态、token 与耗时; 不存提示词、回复与密钥。写入在独立短事务里, 失败只记日志,
 * 从不让调用方失败; 业务数据清空排水期间跳过(表会被清空)。
 */
@Slf4j
@Service
public class AiCallLogService {

    private final NamedParameterJdbcTemplate jdbc;
    private final TransactionTemplate requiresNew;
    private final BusinessDataResetGatePort resetGate;

    public AiCallLogService(NamedParameterJdbcTemplate jdbc, PlatformTransactionManager transactionManager,
                            BusinessDataResetGatePort resetGate) {
        this.jdbc = jdbc;
        this.resetGate = resetGate;
        this.requiresNew = new TransactionTemplate(transactionManager);
        this.requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.requiresNew.setTimeout(10);
    }

    /** 一次调用尝试。 */
    public record CallRecord(String purpose, UUID providerId, String providerName, String model, String protocol,
                             boolean ok, String errorCategory, Integer httpStatus, Integer inputTokens,
                             Integer outputTokens, long latencyMs, UUID jobId, UUID userId) {
    }

    /** 写一行; 任何失败都吞掉(记日志)。 */
    public void record(CallRecord call) {
        if (!resetGate.tryEnter()) {
            return;
        }
        try {
            requiresNew.executeWithoutResult(status -> jdbc.update("""
                    INSERT INTO ai_call_logs (purpose, provider_id, provider_name, model, protocol, ok,
                                              error_category, http_status, input_tokens, output_tokens,
                                              latency_ms, job_id, user_id)
                    SELECT :purpose, p.id, :providerName, :model, :protocol, :ok,
                           :errorCategory, :httpStatus, :inputTokens, :outputTokens,
                           :latencyMs, :jobId, :userId
                    FROM (SELECT CAST(:providerId AS uuid) AS wanted) w
                    LEFT JOIN ai_providers p ON p.id = w.wanted
                    """, new MapSqlParameterSource()
                    .addValue("purpose", truncate(call.purpose(), 48))
                    .addValue("providerId", call.providerId())
                    .addValue("providerName", truncate(call.providerName(), 64))
                    .addValue("model", truncate(call.model(), 128))
                    .addValue("protocol", truncate(call.protocol(), 24))
                    .addValue("ok", call.ok())
                    .addValue("errorCategory", truncate(call.errorCategory(), 32))
                    .addValue("httpStatus", call.httpStatus())
                    .addValue("inputTokens", nonNegative(call.inputTokens()))
                    .addValue("outputTokens", nonNegative(call.outputTokens()))
                    .addValue("latencyMs", (int) Math.max(0, Math.min(Integer.MAX_VALUE, call.latencyMs())))
                    .addValue("jobId", call.jobId())
                    .addValue("userId", call.userId())));
        } catch (RuntimeException e) {
            log.warn("AI call log write failed: {}", e.getClass().getSimpleName());
        } finally {
            resetGate.leave();
        }
    }

    /** 今天(上海时区)已用 token。 */
    @Transactional(readOnly = true)
    public long todayTokens() {
        Long total = jdbc.queryForObject("""
                SELECT COALESCE(SUM(COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)), 0)
                FROM ai_call_logs
                WHERE created_at >= (date_trunc('day', now() AT TIME ZONE 'Asia/Shanghai')
                                     AT TIME ZONE 'Asia/Shanghai')
                """, new MapSqlParameterSource(), Long.class);
        return total == null ? 0L : total;
    }

    /** 近 {@code days} 天按服务商汇总。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<AiProviderDtos.UsageRow> usage(int days) {
        List<AiProviderDtos.UsageRow> rows = new ArrayList<>();
        jdbc.query("""
                SELECT provider_id,
                       (array_agg(provider_name ORDER BY created_at DESC))[1] AS provider_name,
                       count(*) AS calls,
                       count(*) FILTER (WHERE ok) AS ok_calls,
                       COALESCE(SUM(input_tokens), 0) AS input_tokens,
                       COALESCE(SUM(output_tokens), 0) AS output_tokens,
                       COALESCE(ROUND(AVG(latency_ms)), 0) AS average_latency
                FROM ai_call_logs
                WHERE created_at >= now() - make_interval(days => :days)
                GROUP BY provider_id
                ORDER BY count(*) DESC
                """, new MapSqlParameterSource("days", days), rs -> {
            rows.add(new AiProviderDtos.UsageRow(
                    rs.getObject("provider_id", UUID.class),
                    rs.getString("provider_name"),
                    rs.getLong("calls"),
                    rs.getLong("ok_calls"),
                    rs.getLong("input_tokens"),
                    rs.getLong("output_tokens"),
                    rs.getLong("average_latency")));
        });
        return rows;
    }

    /** 删除超过保留期的记录, 每批 5000 行; 返回删除行数。 */
    public int purgeOlderThanDays(int days) {
        int total = 0;
        for (int batch = 0; batch < 100; batch++) {
            Integer deleted = requiresNew.execute(status -> jdbc.update("""
                    UPDATE ai_call_logs SET archived_at=now(),archived_by='system:ai-call-retention',archive_reason='TECHNICAL_LOG_RETENTION_WINDOW'
                    WHERE id IN (SELECT id FROM ai_call_logs
                                 WHERE archived_at IS NULL AND created_at < now() - make_interval(days => :days)
                                 ORDER BY created_at,id
                                 LIMIT 5000)
                    """, new MapSqlParameterSource("days", days)));
            int count = deleted == null ? 0 : deleted;
            total += count;
            if (count < 5000) {
                break;
            }
        }
        return total;
    }

    private static Integer nonNegative(Integer value) {
        return value == null ? null : Math.max(0, value);
    }

    private static String truncate(String value, int max) {
        if (value == null || value.length() <= max) {
            return value;
        }
        return value.substring(0, max);
    }
}
