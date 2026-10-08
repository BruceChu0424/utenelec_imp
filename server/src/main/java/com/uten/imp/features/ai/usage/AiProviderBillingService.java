package com.uten.imp.features.ai.usage;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Currency;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;
import java.util.UUID;

@Service
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class AiProviderBillingService {
    private final NamedParameterJdbcTemplate jdbc;
    private final AiUsageAdminAccess access;
    private final AuditService audit;
    public AiProviderBillingService(NamedParameterJdbcTemplate jdbc, AiUsageAdminAccess access, AuditService audit) {
        this.jdbc = jdbc; this.access = access; this.audit = audit;
    }
    @Transactional(readOnly = true)
    public AiUsageDtos.Billing get(UUID id) {
        access.require();
        return read(id);
    }
    @Transactional
    public AiUsageDtos.Billing save(UUID id, AiUsageDtos.BillingRequest request) {
        var actor = access.require();
        if (request == null || request.version() == null || request.version() < 0
                || !Set.of("UNKNOWN", "METERED", "SUBSCRIPTION").contains(request.billingMode() == null ? "" : request.billingMode())) throw invalid();
        String currency = request.currency() == null || request.currency().isBlank() ? null : request.currency().strip();
        if (currency != null) {
            try { if (!currency.matches("[A-Z]{3}")) throw new IllegalArgumentException(); Currency.getInstance(currency); }
            catch (IllegalArgumentException malformed) { throw invalid(); }
        }
        BigDecimal input = "METERED".equals(request.billingMode()) ? price(request.inputPerMillion()) : null;
        BigDecimal output = "METERED".equals(request.billingMode()) ? price(request.outputPerMillion()) : null;
        if ("METERED".equals(request.billingMode()) && (currency == null || input == null || output == null)) throw invalid();
        // 套餐额度只在套餐模式保存; 其他模式一律清空, 免得切回按量时残留旧额度误导看板。
        Integer quota5h = "SUBSCRIPTION".equals(request.billingMode()) ? quota(request.quota5h()) : null;
        Integer quotaWeekly = "SUBSCRIPTION".equals(request.billingMode()) ? quota(request.quotaWeekly()) : null;
        int updated = jdbc.update("""
                UPDATE ai_providers SET billing_mode=:mode,billing_currency=:currency,
                    billing_input_per_million=:input,billing_output_per_million=:output,billing_model=model,
                    billing_quota_5h=:quota5h,billing_quota_weekly=:quotaWeekly,
                    version=version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND NOT is_deleted AND version=:version
                """, new MapSqlParameterSource("id", id).addValue("version", request.version())
                .addValue("mode", request.billingMode()).addValue("currency", currency).addValue("input", input)
                .addValue("output", output).addValue("quota5h", quota5h).addValue("quotaWeekly", quotaWeekly)
                .addValue("actor", actor.getId()));
        if (updated != 1) throw new ApiException(ErrorCode.CONFLICT, "配置有变化，请刷新后再保存");
        var result = read(id);
        var change = new LinkedHashMap<String, Object>();
        change.put("billingMode", result.billingMode()); change.put("model", result.model()); change.put("currency", result.currency());
        change.put("inputPerMillion", result.inputPerMillion()); change.put("outputPerMillion", result.outputPerMillion());
        change.put("quota5h", result.quota5h()); change.put("quotaWeekly", result.quotaWeekly());
        audit.logCommittedChange(actor.getId(), actor.getLoginAccount(), "update_ai_billing", "ai_providers", id.toString(), "success", change);
        return result;
    }
    private AiUsageDtos.Billing read(UUID id) {
        record Row(long version, String model, String billingModel, String mode, String currency,
                   BigDecimal input, BigDecimal output, Integer quota5h, Integer quotaWeekly) {}
        Row row = jdbc.query("""
                SELECT version,model,billing_model,billing_mode,billing_currency,
                    billing_input_per_million,billing_output_per_million,billing_quota_5h,billing_quota_weekly
                FROM ai_providers WHERE id=:id AND NOT is_deleted
                """, new MapSqlParameterSource("id", id), (rs, r) -> new Row(rs.getLong("version"), rs.getString("model"),
                rs.getString("billing_model"), rs.getString("billing_mode"), rs.getString("billing_currency"),
                rs.getBigDecimal("billing_input_per_million"), rs.getBigDecimal("billing_output_per_million"),
                rs.getObject("billing_quota_5h", Integer.class), rs.getObject("billing_quota_weekly", Integer.class)))
                .stream().findFirst().orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "AI 服务不存在"));
        boolean stale = "METERED".equals(row.mode()) && !row.model().equals(row.billingModel());
        record Used(long h5, long week) {}
        // 服务商没有公开的额度查询接口; 全部调用都走本平台网关, 已用按成功调用自动统计。
        Used used = jdbc.queryForObject("""
                SELECT count(*) FILTER (WHERE created_at >= now() - interval '5 hours'),
                       count(*) FILTER (WHERE created_at >= now() - interval '7 days')
                FROM ai_call_logs WHERE provider_id=:id AND ok
                """, new MapSqlParameterSource("id", id),
                (rs, r) -> new Used(rs.getLong(1), rs.getLong(2)));
        boolean configured = row.quota5h() != null || row.quotaWeekly() != null;
        var quota = new AiUsageDtos.Quota(configured ? "LOGGED" : "NOT_CONFIGURED", null, List.of(
                new AiUsageDtos.QuotaWindow("FIVE_HOURS", used.h5(), row.quota5h() == null ? null : row.quota5h().longValue()),
                new AiUsageDtos.QuotaWindow("WEEKLY", used.week(), row.quotaWeekly() == null ? null : row.quotaWeekly().longValue())));
        return new AiUsageDtos.Billing(id, row.model(), row.version(),
                stale ? "UNKNOWN" : row.mode(), row.currency(),
                stale ? null : decimal(row.input()), stale ? null : decimal(row.output()),
                row.quota5h() == null ? null : row.quota5h().longValue(),
                row.quotaWeekly() == null ? null : row.quotaWeekly().longValue(),
                quota);
    }
    private static BigDecimal price(String raw) {
        if (raw == null || raw.isBlank()) return null;
        try {
            if (!raw.matches("[0-9]{1,8}(?:\\.[0-9]{1,10})?")) throw new IllegalArgumentException();
            BigDecimal value = new BigDecimal(raw);
            if (value.compareTo(new BigDecimal("1000000")) > 0) throw new IllegalArgumentException();
            return value;
        } catch (IllegalArgumentException invalid) { throw invalid(); }
    }
    /** 套餐额度次数: 空=未配置; 填了需为 1..10,000,000。 */
    private static Integer quota(Integer raw) {
        if (raw == null) return null;
        if (raw < 1 || raw > 10_000_000) throw invalid();
        return raw;
    }
    private static String decimal(BigDecimal value) { return value == null ? null : value.stripTrailingZeros().toPlainString(); }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "请核对计费方式、币种和每百万 token 的输入、输出单价"); }
}
