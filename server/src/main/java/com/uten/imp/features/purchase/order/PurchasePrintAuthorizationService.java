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
        if(documents==null||documents.isEmpty()||documents.size()>100||documents.stream().map(PurchasePrintAuthorizationController.DocumentProof::id).distinct().count()!=documents.size())
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请按原批次核对采购打印快照，最多100份");
        var actor=users.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        String before=scopes.scopeFor("native_purchase_owner",actor,false);
        // Each original read opens its current read-only RR snapshot. No long-lived business row locks.
        for(var expected:documents) {
            var current=print.read(expected.id());
            if(expected.contentDigest()==null||!expected.contentDigest().equals(current.contentDigest()))
                throw new ApiException(ErrorCode.CONFLICT,"采购单内容、财务进度或可见字段已变化，请按当前资料重新生成；本次未发布文件");
        }
        if(!before.equals(scopes.scopeFor("native_purchase_owner",actor,false)))
            throw new ApiException(ErrorCode.READ_SCOPE_CHANGED,"采购打印范围已变化，请重新核对原批次");
    }
}
