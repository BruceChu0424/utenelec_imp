package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.Set;

/** Internal resource purposes, not permission codes or independently grantable capabilities. */
public enum BusinessEmployeeReferencePurpose {
    WAREHOUSE_ARRIVAL_RECEIVER(Set.of("warehouse_inbound:view","warehouse_inbound:stock_in")),
    WAREHOUSE_SUBCONTRACT_OPERATOR(Set.of("subcontract_outbound:view","subcontract_outbound:execute",
            "subcontract_material_issue:view","subcontract_material_issue:edit")),
    WORKSHOP_MATERIAL_ISSUER(Set.of("workshop_material:issue"));

    private final Set<String> authorities;
    BusinessEmployeeReferencePurpose(Set<String> authorities) {this.authorities=authorities;}
    public Set<String> authorities() {return authorities;}
    public static BusinessEmployeeReferencePurpose parse(String value) {
        try {return valueOf(value==null?"":value);}
        catch(IllegalArgumentException invalid) {throw new ApiException(ErrorCode.VALIDATION_FAILED,"人员引用业务场景无效");}
    }
}
