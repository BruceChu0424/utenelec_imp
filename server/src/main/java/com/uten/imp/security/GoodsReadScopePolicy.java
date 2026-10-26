package com.uten.imp.security;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.Set;

/** One configured goods ownership authority for list/export rows and their authorization proofs. */
@Component
public final class GoodsReadScopePolicy {
    private final OwnerVisibility owners;
    @Value("${uten.features.goods-owner-scope-enabled:false}")
    private boolean ownerScopeEnabled;

    public GoodsReadScopePolicy(OwnerVisibility owners) { this.owners = owners; }

    public OwnerVisibility.OwnerScope evaluate() {
        return ownerScopeEnabled ? owners.evaluate("goods", "goods:view:all")
                : new OwnerVisibility.OwnerScope(true, Set.of());
    }

    /** Null preserves the versioner's FEATURE contract when ownership is configured off. */
    public OwnerVisibility.OwnerScope versionedReadScope() { return ownerScopeEnabled ? evaluate() : null; }
}
