package com.uten.imp.features.purchase.order;

import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import java.util.*;

/** Reauthorize the exact snapshots that were rendered, without silently replacing any completed PDF. */
@Service
public class PurchasePrintAuthorizationService {
    private final PurchaseOrderPrintService print;
    private final SecurityContextCurrentUser users;
    private final ReadScopeVersionAuthority scopes;
    public PurchasePrintAuthorizationService(PurchaseOrderPrintService print,SecurityContextCurrentUser users,ReadScopeVersionAuthority scopes){this.print=print;this.users=users;this.scopes=scopes;}
    @PreAuthorize("hasAnyAuthority('purchase_order:view','finance_order_approval:view')")
    public void authorize(List<PurchasePrintAuthorizationController.DocumentProof> documents) {
        com.uten.imp.common.export.ProcurementPrintAuthorization.authorize(
                documents == null ? null : documents.stream().map(proof -> proof == null ? null :
                    new com.uten.imp.common.export.ProcurementPrintAuthorization.Proof(proof.id(), proof.contentDigest())).toList(),
                "native_purchase_owner", users, scopes, print::read);
    }
}
