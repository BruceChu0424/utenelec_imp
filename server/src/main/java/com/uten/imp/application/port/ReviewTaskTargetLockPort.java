package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Financial review targets expose their business-header then case lock order without a service dependency cycle. */
public interface ReviewTaskTargetLockPort {
    /** Existing target families preserve their read scope; narrower participants supply a batched object filter. */
    default java.util.Set<String> readableTargetKeys(java.util.Collection<String> targetKeys){return java.util.Set.copyOf(targetKeys);}
    String targetType();
    List<Target> resolve(List<String> targetKeys, boolean requireExisting);
    void lockHeader(Target target, boolean requireReviewable);
    void lockTarget(Target target, boolean requireReviewable);
    default boolean canViewTarget(String targetKey) { return true; }

    record Target(String targetKey, String aggregateType, UUID aggregateId, UUID targetId) {}
}
