package com.uten.imp.features.admin.serverstatus;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * 数据生命周期策略清册读取（B3，V954）。
 *
 * <p>清册按当前真实行为由迁移种子登记（用途、留存合同、期限口径、分层路径、
 * 权威真源、维护任务）；本服务只读暴露，不在运行时改写策略——策略变更走前向迁移，
 * 保证清册与实际行为同批生效。
 */
@Service
@RequiredArgsConstructor(onConstructor_ = @org.springframework.beans.factory.annotation.Autowired)
public class DataLifecyclePolicyService {

    private final JdbcTemplate jdbc;

    public record PolicyRow(
            String policyKey,
            String domain,
            String subject,
            String purpose,
            String retentionContract,
            String termNote,
            String tierPath,
            String authoritativeNote,
            String housekeepingTask) {}

    @Transactional(readOnly = true)
    public List<PolicyRow> list() {
        return jdbc.query("""
                SELECT policy_key, domain, subject, purpose, retention_contract,
                       term_note, tier_path, authoritative_note, housekeeping_task
                FROM data_lifecycle_policies
                ORDER BY domain, policy_key
                """,
                (rs, n) -> new PolicyRow(
                        rs.getString("policy_key"),
                        rs.getString("domain"),
                        rs.getString("subject"),
                        rs.getString("purpose"),
                        rs.getString("retention_contract"),
                        rs.getString("term_note"),
                        rs.getString("tier_path"),
                        rs.getString("authoritative_note"),
                        rs.getString("housekeeping_task")));
    }

    /** 清册覆盖的类别数与合同分布（容量/治理概览用）。 */
    @Transactional(readOnly = true)
    public List<PolicyRow> byContract(String retentionContract) {
        return jdbc.query("""
                SELECT policy_key, domain, subject, purpose, retention_contract,
                       term_note, tier_path, authoritative_note, housekeeping_task
                FROM data_lifecycle_policies
                WHERE retention_contract = ?
                ORDER BY domain, policy_key
                """,
                (rs, n) -> new PolicyRow(
                        rs.getString("policy_key"),
                        rs.getString("domain"),
                        rs.getString("subject"),
                        rs.getString("purpose"),
                        rs.getString("retention_contract"),
                        rs.getString("term_note"),
                        rs.getString("tier_path"),
                        rs.getString("authoritative_note"),
                        rs.getString("housekeeping_task")),
                retentionContract);
    }
}
