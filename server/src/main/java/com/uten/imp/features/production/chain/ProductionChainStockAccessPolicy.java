package com.uten.imp.features.production.chain;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/**
 * Stock-document owner scope used by the production chain health read model.
 */
@Component
public class ProductionChainStockAccessPolicy
        extends DocumentAccessPolicy {

    public ProductionChainStockAccessPolicy(
            OwnerVisibility ownerVisibility,
            SecurityContextCurrentUser currentUser) {
        super(
                "stock_doc",
                "stock_doc:view:all",
                ownerVisibility,
                currentUser);
    }
}
