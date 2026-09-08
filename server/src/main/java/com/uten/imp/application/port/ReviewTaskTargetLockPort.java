package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Financial review targets expose their business-header then case lock order without a service dependency cycle. */
public interface ReviewTaskTargetLockPort {
    String targetType();
    List<Target> resolve(List<String> targetKeys, boolean requireExisting);
    void lockHeader(Target target, boolean requireReviewable);
    void lockTarget(Target target, boolean requireReviewable);

    record Target(String targetKey, String aggregateType, UUID aggregateId, UUID targetId) {}
}
