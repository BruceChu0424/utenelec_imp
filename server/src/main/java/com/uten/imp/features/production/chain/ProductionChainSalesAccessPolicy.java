package com.uten.imp.features.production.chain;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/**
 * Sales-owner scope used only by the cross-chain production health read model.
 *
 * <p>This adapter depends on the platform security foundation instead of the
 * sales feature, preserving the production module boundary.
 */
@Component
public class ProductionChainSalesAccessPolicy
        extends DocumentAccessPolicy {

    public ProductionChainSalesAccessPolicy(
            OwnerVisibility ownerVisibility,
            SecurityContextCurrentUser currentUser) {
        super("sales", "sales:view:all", ownerVisibility, currentUser);
    }
}
