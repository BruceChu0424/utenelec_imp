package com.uten.imp.features.ai.chat;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.features.ai.job.AiJobView;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.springframework.context.annotation.Lazy;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Owner checks and current authorization apply both to conversation history and uploaded sources. */
@Component
public class AiChatEvidence {
    private final AiJobService jobs;
    private final JdbcTemplate jdbc;
    private final AiChatAccessPolicy access;
    private final SubmitterPrincipalRestorer principals;
    public AiChatEvidence(@Lazy AiJobService jobs, JdbcTemplate jdbc, AiChatAccessPolicy access,
                          SubmitterPrincipalRestorer principals) {
        this.jobs = jobs; this.jdbc = jdbc; this.access = access; this.principals = principals;
    }
    public Map<String, Object> stamp() {
        AuthUser actor = access.requireChat();
        var stamps = principals.currentStamps(actor.getId()).orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return Map.of("actor", actor.getId().toString(), "authVersion", stamps.authVersion(),
                "epoch", stamps.authorizationEpoch(), "memberships", access.membershipFingerprint());
    }
    public void requireStamp(Object value) {
        if (!(value instanceof Map<?, ?> stored)) throw changed();
        Map<String, Object> now = stamp();
        for (String key : now.keySet()) {
            if (!Objects.equals(String.valueOf(now.get(key)), String.valueOf(stored.get(key)))) throw changed();
        }
    }
    public AiJobView previous(UUID id) {
        AiJobView job = jobs.view(id, access.requireChat());
        if (!AiChatJobHandler.KIND.equals(job.kind()) || !"SUCCEEDED".equals(job.status()) || job.result() == null)
            throw new ApiException(ErrorCode.NOT_FOUND, "上轮对话不存在或已过期，请开始新对话");
        return job;
    }
    public void requireOrderAttachment(UUID id) {
        access.requireDomain("SALES");
        AuthUser actor = access.requireChat();
        if (!(actor.isSuperAdmin() || actor.getPermissions().containsAll(java.util.Set.of("sales_order:view", "sales_order:create"))))
            throw new ApiException(ErrorCode.FORBIDDEN, "你没有新建订货单的权限");
        // The public view reapplies the existing intake handler's row/field authorization.
        AiJobView job = jobs.view(id, actor);
        if (!"SALES_DOCUMENT_INTAKE".equals(job.kind()) || !"SUCCEEDED".equals(job.status()) || job.result() == null)
            throw new ApiException(ErrorCode.NOT_FOUND, "识别文件不存在、尚未完成或已经使用");
        Boolean valid = jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM ai_jobs WHERE id=? AND submitted_by_user=?
                  AND kind='SALES_DOCUMENT_INTAKE' AND params->>'docType'='order'
                  AND NOT jsonb_exists(params, 'docId') AND used_at IS NULL AND result_purged_at IS NULL
                  AND submitted_auth_version=(SELECT auth_version FROM users WHERE id=?)
                  AND submitted_auth_epoch=(SELECT epoch FROM authorization_state WHERE singleton_id=1))
                """, Boolean.class, id, actor.getId(), actor.getId());
        if (!Boolean.TRUE.equals(valid)) throw changed();
    }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN, "账号权限或部门已变化，请开始新对话并重新选择文件"); }
}
