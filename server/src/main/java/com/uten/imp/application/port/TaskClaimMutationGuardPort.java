package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Transactional mutation boundary shared by business owners and their pooled review tasks. */
public interface TaskClaimMutationGuardPort {
    record ClaimExpectation(String targetKey,UUID expectedClaimId) {}
    void requireNoActiveClaim(String targetType,String targetKey);
    void requireActiveClaimByMe(String targetType,String targetKey,UUID expectedClaimId);
    void requireActiveClaimsByMe(String targetType,List<ClaimExpectation> expectations);
    void release(String targetType,String targetKey);
}
