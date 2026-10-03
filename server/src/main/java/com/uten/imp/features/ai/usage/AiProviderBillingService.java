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
        int updated = jdbc.update("""
                UPDATE ai_providers SET billing_mode=:mode,billing_currency=:currency,
                    billing_input_per_million=:input,billing_output_per_million=:output,billing_model=model,
                    version=version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND NOT is_deleted AND version=:version
                """, new MapSqlParameterSource("id", id).addValue("version", request.version())
                .addValue("mode", request.billingMode()).addValue("currency", currency).addValue("input", input)
                .addValue("output", output).addValue("actor", actor.getId()));
        if (updated != 1) throw new ApiException(ErrorCode.CONFLICT, "配置有变化，请刷新后再保存");
        var result = read(id);
        var change = new LinkedHashMap<String, Object>();
        change.put("billingMode", result.billingMode()); change.put("model", result.model()); change.put("currency", result.currency());
        change.put("inputPerMillion", result.inputPerMillion()); change.put("outputPerMillion", result.outputPerMillion());
        audit.logCommittedChange(actor.getId(), actor.getLoginAccount(), "update_ai_billing", "ai_providers", id.toString(), "success", change);
        return result;
    }
    private AiUsageDtos.Billing read(UUID id) {
        return jdbc.query("""
                SELECT id,model,version,billing_mode,billing_currency,billing_input_per_million,
                    billing_output_per_million,billing_model
                FROM ai_providers WHERE id=:id AND NOT is_deleted
                """, new MapSqlParameterSource("id", id), (rs, row) -> {
            boolean stale = "METERED".equals(rs.getString("billing_mode")) && !rs.getString("model").equals(rs.getString("billing_model"));
            return new AiUsageDtos.Billing(rs.getObject("id", UUID.class), rs.getString("model"), rs.getLong("version"),
                    stale ? "UNKNOWN" : rs.getString("billing_mode"), rs.getString("billing_currency"),
                    stale ? null : decimal(rs.getBigDecimal("billing_input_per_million")),
                    stale ? null : decimal(rs.getBigDecimal("billing_output_per_million")),
                    new AiUsageDtos.Quota("UNSUPPORTED", "暂未接入服务商套餐额度查询", List.of()));
        }).stream().findFirst().orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "AI 服务不存在"));
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
    private static String decimal(BigDecimal value) { return value == null ? null : value.stripTrailingZeros().toPlainString(); }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "请核对计费方式、币种和每百万 token 的输入、输出单价"); }
}
