package com.uten.imp.features.ai.usage;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Bounded administrative projection: never selects raw input, provider prompts or business replies. */
@Service
public class AiUsageAuditService {
    private final NamedParameterJdbcTemplate jdbc;
    private final AiUsageAdminAccess access;
    private final AuditService audit;
    public AiUsageAuditService(NamedParameterJdbcTemplate jdbc, AiUsageAdminAccess access, AuditService audit) {
        this.jdbc = jdbc; this.access = access; this.audit = audit;
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, timeout = 20)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiUsageDtos.Audit query(int days, int page, int size, UUID userId, UUID providerId) {
        var actor = access.require();
        if (days < 1 || days > 366 || page < 0 || page > 100_000 || size < 1 || size > 100)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请调整查询时间或页数");
        var params = new MapSqlParameterSource("days", days).addValue("user", userId)
                .addValue("provider", providerId).addValue("limit", size).addValue("offset", (long) page * size);
        // Every query in this read sees the same database snapshot and the same now() boundary.
        final List<AiUsageDtos.Cost> totalCosts = jdbc.query(CTE + COST_TOTAL, params, (rs, row) -> cost(rs));
        AiUsageDtos.Summary summary = jdbc.queryForObject(CTE + """
                SELECT count(*) AS uses,coalesce(sum(calls),0) AS calls,coalesce(sum(ok_calls),0) AS ok_calls,
                  count(*) FILTER(WHERE local_use) AS local_uses,
                  CASE WHEN coalesce(sum(unknown_input),0)>0 THEN NULL ELSE coalesce(sum(input_tokens),0) END AS input_tokens,
                  CASE WHEN coalesce(sum(unknown_output),0)>0 THEN NULL ELSE coalesce(sum(output_tokens),0) END AS output_tokens,
                  coalesce(sum(unknown_tokens),0) AS unknown_tokens,coalesce(sum(unknown_cost),0) AS unknown_cost
                FROM events
                """, params, (rs, row) -> new AiUsageDtos.Summary(rs.getLong("uses"), rs.getLong("calls"), rs.getLong("ok_calls"),
                rs.getLong("local_uses"), nullableLong(rs,"input_tokens"), nullableLong(rs,"output_tokens"),
                rs.getLong("unknown_tokens"), rs.getLong("unknown_cost"), totalCosts));

        Map<UUID,List<AiUsageDtos.Cost>> userCosts = groupedCosts(CTE + """
                SELECT user_id AS owner,billing_currency AS currency,basis,sum(amount) AS amount
                FROM period_calls WHERE amount IS NOT NULL AND user_id IS NOT NULL
                GROUP BY user_id,billing_currency,basis ORDER BY billing_currency,basis
                """, params);
        var users = jdbc.query(CTE + """
                SELECT e.user_id,max(e.name) AS name,max(e.code) AS code,count(*) AS uses,sum(e.calls) AS calls,
                       sum(e.unknown_cost) AS unknown_cost
                FROM named_events e WHERE user_id IS NOT NULL GROUP BY e.user_id
                ORDER BY count(*) DESC,e.user_id
                """, params, (rs, row) -> new AiUsageDtos.User(rs.getObject("user_id",UUID.class),rs.getString("name"),rs.getString("code"),
                rs.getLong("uses"),rs.getLong("calls"),rs.getLong("unknown_cost"),userCosts.getOrDefault(rs.getObject("user_id",UUID.class),List.of())));

        var records = jdbc.query(CTE + "SELECT * FROM named_events ORDER BY created_at DESC,id DESC LIMIT :limit OFFSET :offset", params,
                (rs,row) -> new AiUsageDtos.Use(rs.getObject("id",UUID.class),rs.getObject("job_id",UUID.class),
                        rs.getObject("created_at",OffsetDateTime.class),rs.getObject("finished_at",OffsetDateTime.class),
                        rs.getObject("user_id",UUID.class),rs.getObject("employee_id",UUID.class),rs.getString("name"),rs.getString("code"),
                        rs.getString("kind"),rs.getString("question"),rs.getString("question_state"),rs.getString("status"),rs.getString("intent"),
                        rs.getLong("calls"),nullableLong(rs,"input_tokens"),nullableLong(rs,"output_tokens"),
                        rs.getLong("unknown_tokens"),rs.getLong("unknown_cost"),List.of(),strings(rs,"provider_names"),strings(rs,"models")));
        if (!records.isEmpty()) {
            params.addValue("ids",records.stream().map(AiUsageDtos.Use::id).toList());
            Map<UUID,List<AiUsageDtos.Cost>> recordCosts = groupedCosts(CTE + """
                    SELECT event_id AS owner,billing_currency AS currency,basis,sum(amount) AS amount
                    FROM period_calls WHERE amount IS NOT NULL AND event_id IN (:ids)
                    GROUP BY event_id,billing_currency,basis ORDER BY billing_currency,basis
                    """, params);
            records = records.stream().map(r -> new AiUsageDtos.Use(r.id(),r.jobId(),r.createdAt(),r.finishedAt(),r.userId(),r.employeeId(),
                    r.name(),r.code(),r.kind(),r.question(),r.questionState(),r.status(),r.intent(),r.calls(),r.inputTokens(),r.outputTokens(),
                    r.unknownTokenCalls(),r.unknownCostCalls(),recordCosts.getOrDefault(r.id(),List.of()),r.providerNames(),r.models())).toList();
        }
        audit.logExplicit(actor.getId(),actor.getLoginAccount(),"view_ai_usage_audit","ai_jobs",actor.getId().toString(),
                "查看 AI 使用记录：近" + days + "天，第" + (page + 1) + "页");
        return new AiUsageDtos.Audit(days,page,size,summary.uses(),summary,users,records);
    }

    private static Long nullableLong(ResultSet rs,String name) throws SQLException {
        long value=rs.getLong(name); return rs.wasNull() ? null : value;
    }
    private static List<String> strings(ResultSet rs,String name) throws SQLException {
        var array=rs.getArray(name);
        if (array==null) return List.of();
        try { return java.util.Arrays.stream((Object[])array.getArray()).filter(java.util.Objects::nonNull).map(Object::toString).toList(); }
        finally { array.free(); }
    }
    private static AiUsageDtos.Cost cost(ResultSet rs) throws SQLException {
        return new AiUsageDtos.Cost(rs.getString("currency"),rs.getBigDecimal("amount").stripTrailingZeros().toPlainString(),rs.getString("basis"));
    }
    private Map<UUID,List<AiUsageDtos.Cost>> groupedCosts(String sql,MapSqlParameterSource params) {
        Map<UUID,List<AiUsageDtos.Cost>> result = new HashMap<>();
        jdbc.query(sql,params,(org.springframework.jdbc.core.RowCallbackHandler) rs ->
                result.computeIfAbsent(rs.getObject("owner",UUID.class),ignored -> new ArrayList<>()).add(cost(rs)));
        result.replaceAll((key,value) -> List.copyOf(value)); return result;
    }

    private static final String COST_TOTAL = """
            SELECT billing_currency AS currency,basis,sum(amount) AS amount FROM period_calls
            WHERE amount IS NOT NULL GROUP BY billing_currency,basis ORDER BY billing_currency,basis
            """;
    private static final String CTE = """
            WITH period_calls AS MATERIALIZED (
              SELECT c.*,coalesce(j.id,c.id) AS event_id,j.id AS linked_job,
                CASE WHEN c.input_tokens IS NOT NULL AND (c.usage_capture_version>0 OR c.input_tokens>0) THEN c.input_tokens END AS known_input,
                CASE WHEN c.output_tokens IS NOT NULL AND (c.usage_capture_version>0 OR c.output_tokens>0) THEN c.output_tokens END AS known_output,
                CASE WHEN c.actual_cost IS NOT NULL AND nullif(c.actual_cost_source,'') IS NOT NULL THEN c.actual_cost ELSE c.estimated_cost END AS amount,
                CASE WHEN c.actual_cost IS NOT NULL AND nullif(c.actual_cost_source,'') IS NOT NULL THEN 'ACTUAL' ELSE 'ESTIMATED' END AS basis
              FROM ai_call_logs c LEFT JOIN ai_jobs j ON j.id=c.job_id AND j.submitted_by_user=c.user_id AND j.created_at<=now()
              WHERE c.created_at >= now()-make_interval(days=>:days) AND c.created_at<=now()
                AND (CAST(:user AS uuid) IS NULL OR c.user_id=CAST(:user AS uuid))
                AND (CAST(:provider AS uuid) IS NULL OR c.provider_id=CAST(:provider AS uuid))
            ), call_totals AS (
              SELECT event_id,count(*) AS calls,count(*) FILTER(WHERE ok) AS ok_calls,
                sum(known_input) AS input_tokens,sum(known_output) AS output_tokens,
                count(*) FILTER(WHERE known_input IS NULL) AS unknown_input,
                count(*) FILTER(WHERE known_output IS NULL) AS unknown_output,
                count(*) FILTER(WHERE known_input IS NULL OR known_output IS NULL) AS unknown_tokens,
                count(*) FILTER(WHERE amount IS NULL) AS unknown_cost,
                array_agg(DISTINCT provider_name::text) FILTER(WHERE provider_name IS NOT NULL) AS provider_names,
                array_agg(DISTINCT model::text) FILTER(WHERE model IS NOT NULL) AS models
              FROM period_calls GROUP BY event_id
            ), selected_jobs AS (
              SELECT j.id,j.created_at,j.finished_at,j.submitted_by_user,j.submitted_by_employee,j.kind,j.status,j.ai_calls,
                j.audit_question,j.audit_question_state,j.audit_intent,j.audit_tool,
                CASE WHEN CAST(:provider AS uuid) IS NULL AND j.created_at>=now()-make_interval(days=>:days)
                  THEN greatest(j.ai_calls-(SELECT count(*) FROM ai_call_logs old WHERE old.job_id=j.id AND old.user_id=j.submitted_by_user),0)
                  ELSE 0 END AS missing_calls
              FROM ai_jobs j WHERE j.created_at<=now()
                AND (j.created_at>=now()-make_interval(days=>:days) OR EXISTS(SELECT 1 FROM period_calls c WHERE c.linked_job=j.id))
                AND (CAST(:user AS uuid) IS NULL OR j.submitted_by_user=CAST(:user AS uuid))
                AND (CAST(:provider AS uuid) IS NULL OR EXISTS(SELECT 1 FROM period_calls c WHERE c.linked_job=j.id))
            ), events AS (
              SELECT j.id,j.id AS job_id,j.created_at,j.finished_at,j.submitted_by_user AS user_id,j.submitted_by_employee AS employee_id,
                j.kind,j.audit_question AS question,j.audit_question_state AS question_state,j.status,
                coalesce(j.audit_tool,j.audit_intent) AS intent,coalesce(c.calls,0) AS calls,coalesce(c.ok_calls,0) AS ok_calls,
                (coalesce(c.calls,0)=0 AND j.ai_calls=0) AS local_use,
                CASE WHEN coalesce(c.unknown_input,0)+j.missing_calls>0 THEN NULL ELSE coalesce(c.input_tokens,0) END AS input_tokens,
                CASE WHEN coalesce(c.unknown_output,0)+j.missing_calls>0 THEN NULL ELSE coalesce(c.output_tokens,0) END AS output_tokens,
                coalesce(c.unknown_input,0)+j.missing_calls AS unknown_input,coalesce(c.unknown_output,0)+j.missing_calls AS unknown_output,
                coalesce(c.unknown_tokens,0)+j.missing_calls AS unknown_tokens,coalesce(c.unknown_cost,0)+j.missing_calls AS unknown_cost,
                coalesce(c.provider_names,ARRAY[]::text[]) AS provider_names,coalesce(c.models,ARRAY[]::text[]) AS models
              FROM selected_jobs j LEFT JOIN call_totals c ON c.event_id=j.id
              UNION ALL
              SELECT c.id,NULL::uuid,c.created_at,c.created_at,c.user_id,c.employee_id,'PROVIDER_CALL',NULL::text,'NOT_APPLICABLE',
                CASE WHEN c.ok THEN 'SUCCEEDED' ELSE 'FAILED' END,c.purpose,1,CASE WHEN c.ok THEN 1 ELSE 0 END,false,
                c.known_input,c.known_output,CASE WHEN c.known_input IS NULL THEN 1 ELSE 0 END,
                CASE WHEN c.known_output IS NULL THEN 1 ELSE 0 END,
                CASE WHEN c.known_input IS NULL OR c.known_output IS NULL THEN 1 ELSE 0 END,CASE WHEN c.amount IS NULL THEN 1 ELSE 0 END,
                ARRAY[c.provider_name]::text[],ARRAY[c.model]::text[]
              FROM period_calls c WHERE c.linked_job IS NULL
            ), named_events AS (
              SELECT v.*,coalesce(e.full_name,u.login_account,CASE WHEN v.user_id IS NULL THEN '系统' ELSE '已删除员工' END) AS name,
                coalesce(e.code,'') AS code FROM events v LEFT JOIN employees e ON e.id=v.employee_id LEFT JOIN users u ON u.id=v.user_id
            )
            """;
}
