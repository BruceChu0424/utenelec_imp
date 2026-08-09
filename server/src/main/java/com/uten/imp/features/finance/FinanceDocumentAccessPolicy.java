package com.uten.imp.features.finance;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/** Finance document access is scoped by the document maker. */
@Component
public class FinanceDocumentAccessPolicy extends DocumentAccessPolicy {

    public static final String SCOPE = "finance";
    public static final String VIEW_ALL = "finance:view:all";

    public FinanceDocumentAccessPolicy(OwnerVisibility ownerVisibility,
                                       SecurityContextCurrentUser currentUser) {
        super(SCOPE, VIEW_ALL, ownerVisibility, currentUser);
    }
}
