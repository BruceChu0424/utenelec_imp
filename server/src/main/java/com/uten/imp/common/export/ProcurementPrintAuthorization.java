package com.uten.imp.common.export;

import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import java.util.*;
import java.util.function.Function;

/** Reauthorize the original rendered facts immediately before publishing a document batch. */
public final class ProcurementPrintAuthorization {
    private ProcurementPrintAuthorization() { }
    public record Proof(UUID id, String contentDigest) { }
    public static void authorize(List<Proof> documents, String scope,
            SecurityContextCurrentUser users, ReadScopeVersionAuthority scopes,
            Function<UUID,ProcurementOrderPrintDocument> read) {
        if (documents == null || documents.isEmpty() || documents.size() > 100
                || documents.stream().anyMatch(proof -> proof == null || proof.id() == null)
                || documents.stream().map(Proof::id).distinct().count() != documents.size())
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请按原批次核对订货单打印快照，最多100份");
        var actor = users.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        String before = scopes.scopeFor(scope, actor, false);
        for (var expected : documents) {
            var current = read.apply(expected.id());
            if (expected.contentDigest() == null || !expected.contentDigest().equals(current.contentDigest()))
                throw new ApiException(ErrorCode.CONFLICT, "订货单内容、财务进度或可见字段已变化，请按当前资料重新生成；本次未发布文件");
        }
        if (!before.equals(scopes.scopeFor(scope, actor, false)))
            throw new ApiException(ErrorCode.READ_SCOPE_CHANGED, "订货单打印范围已变化，请重新核对原批次");
    }
}
