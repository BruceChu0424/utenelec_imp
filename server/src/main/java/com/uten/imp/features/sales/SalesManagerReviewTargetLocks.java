package com.uten.imp.features.sales;

import com.uten.imp.application.port.ReviewTaskTargetLockPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Component;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

public abstract class SalesManagerReviewTargetLocks implements ReviewTaskTargetLockPort {
    private final EntityManager em;
    private final String kind;
    protected SalesManagerReviewTargetLocks(EntityManager em,String kind) { this.em=em; this.kind=kind; }
    @Override public String targetType() { return "SALES_"+kind.toUpperCase(java.util.Locale.ROOT)+"_MANAGER_REVIEW"; }
    @Override public List<Target> resolve(List<String> keys,boolean requireExisting) {
        var result=new ArrayList<Target>();
        for(String key:keys) {
            try {
                UUID id=UUID.fromString(key);
                if(requireExisting && !id.toString().equals(key)) throw new IllegalArgumentException();
                result.add(new Target(key,"SALES_"+kind.toUpperCase(java.util.Locale.ROOT),id,id));
            } catch(IllegalArgumentException | NullPointerException invalid) {
                if(requireExisting) throw new ApiException(ErrorCode.VALIDATION_FAILED,"单据编号不正确");
            }
        }
        return result;
    }
    @Override public void lockHeader(Target target,boolean requireReviewable) {
        String predicate=requireReviewable ? " AND NOT o.is_deleted AND o.manager_review_state='PENDING' AND "+SalesManagerReviewService.reviewable(kind) : "";
        var rows=em.createNativeQuery("SELECT o.id FROM "+SalesManagerReviewService.table(kind)+" o WHERE o.id=:id"+predicate+" FOR UPDATE")
                .setParameter("id",target.aggregateId()).getResultList();
        if(requireReviewable && rows.isEmpty()) throw new ApiException(ErrorCode.CONFLICT,"单据已不在待负责人审核状态，请刷新");
    }
    @Override public void lockTarget(Target target,boolean requireReviewable) {}
    @Component public static class Quotes extends SalesManagerReviewTargetLocks {
        public Quotes(EntityManager em) { super(em,"quote"); }
    }
    @Component public static class Orders extends SalesManagerReviewTargetLocks {
        public Orders(EntityManager em) { super(em,"order"); }
    }
}
