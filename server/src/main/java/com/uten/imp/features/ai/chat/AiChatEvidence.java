package com.uten.imp.features.ai.chat;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.springframework.context.annotation.Lazy;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Owner checks and current authorization apply to conversation history (ADR-140/ADR-150). */
@Component
public class AiChatEvidence {
    private final AiJobService jobs;
    private final AiChatAccessPolicy access;
    private final SubmitterPrincipalRestorer principals;
    public AiChatEvidence(@Lazy AiJobService jobs, AiChatAccessPolicy access,
                          SubmitterPrincipalRestorer principals) {
        this.jobs = jobs; this.access = access; this.principals = principals;
    }
    public Map<String, Object> stamp() {
        AuthUser actor = access.requireChat();
        var stamps = principals.currentStamps(actor.getId()).orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        return Map.of("actor", actor.getId().toString(), "authVersion", stamps.authVersion(),
                "epoch", stamps.authorizationEpoch(), "memberships", access.membershipFingerprint());
    }
    public void requireStamp(Object value) {
        requireStamp(value, stamp());
    }

    /** Checks a stored stamp against one already computed for the current reader (no queries). */
    static void requireStamp(Object value, Map<String, Object> now) {
        if (!(value instanceof Map<?, ?> stored)) throw changed();
        for (String key : now.keySet()) {
            if (!Objects.equals(String.valueOf(now.get(key)), String.valueOf(stored.get(key)))) throw changed();
        }
    }
    /** Whether a stored stamp still matches the current identity (a non-throwing {@link #requireStamp}). */
    public boolean stampMatches(Object value) {
        try {
            requireStamp(value);
            return true;
        } catch (ApiException changed) {
            if (changed.getCode() != ErrorCode.FORBIDDEN) throw changed;
            return false;
        }
    }

    /**
     * ADR-152: the owner's own earlier turns of one conversation, newest first (successful, not archived,
     * not cleared). Results are raw stored values; the caller re-authorizes each before use.
     */
    public List<AiJobService.OwnedResult> conversation(UUID conversationId, int limit) {
        return jobs.conversationResults(AiChatJobHandler.KIND, access.requireChat(), conversationId, limit);
    }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN, "信息已更新，请重新提问或上传文件。"); }
}
