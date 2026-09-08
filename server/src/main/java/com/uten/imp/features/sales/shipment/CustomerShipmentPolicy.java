package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/** Shared storage never grants one sales page the other page's write permission. */
@Component
@RequiredArgsConstructor
public class CustomerShipmentPolicy {
    public static final String ORDER="ORDER";
    public static final String DIRECT="DIRECT_CUSTOMER";
    public static final String CHARGED="CHARGED";
    public static final String FREE="FREE";
    public static final String CLAIM_TYPE="SALES_SHIPMENT_FINANCE_AUDIT";
    private final SecurityContextCurrentUser currentUser;

    public static String requestedKind(String value) {
        String kind=value==null?ORDER:value.trim().toUpperCase(java.util.Locale.ROOT);
        if(!ORDER.equals(kind)&&!DIRECT.equals(kind))throw new ApiException(ErrorCode.VALIDATION_FAILED,"发货业务类型无效");
        return kind;
    }
    public static boolean direct(SalesShipment shipment){return DIRECT.equals(shipment.getShipmentKind());}
    public static boolean free(SalesShipment shipment){return direct(shipment)&&FREE.equals(shipment.getBillingMode());}
    public static boolean salesConfirmed(SalesShipment shipment) {
        return shipment.getSalesConfirmedAt()!=null&&shipment.getSalesConfirmedBy()!=null
                &&shipment.getSalesConfirmedRevision()!=null
                &&shipment.getSalesConfirmedRevision().longValue()==shipment.getReviewRevision();
    }
    public boolean has(String code){return currentUser.get().map(user->user.isSuperAdmin()||user.getPermissions().contains(code)).orElse(false);}
    public boolean can(String kind,String action){return has((DIRECT.equals(kind)?"sales_other_shipment:":"sales_shipment:")+action);}
    public boolean canRead(String kind){return can(kind,"view")||has("finance_shipment_audit")||has("sales_shipment:warehouse-work");}
    public void require(String kind,String action) {
        if(!can(kind,action))throw new ApiException(ErrorCode.FORBIDDEN,"当前账号无权执行这类发货单的操作");
    }
    public void requireRead(String kind) {
        if(!canRead(kind))throw new ApiException(ErrorCode.FORBIDDEN,"当前账号无权查看这类发货单");
    }
}
