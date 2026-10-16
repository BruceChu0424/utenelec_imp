package com.uten.imp.features.subcontract;

import com.uten.imp.application.port.SubcontractDocumentReadAccessPort;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/**
 * 委外单据行级访问策略：按制单人(maker_id)隔离。薄壳固定 scope=subcontract /
 * viewAll=subcontract:view:all，判定逻辑继承自 {@link DocumentAccessPolicy}。
 *
 * <p>委外订单/询价/发料/退料/进仓/退货/损耗的归属列为 maker_id。委外「申请」是计划系统
 * 生成的只读需求单，不接入本隔离。
 */
@Component
public class SubcontractDocumentAccessPolicy extends DocumentAccessPolicy
        implements SubcontractDocumentReadAccessPort {

    public static final String SCOPE = "subcontract";
    public static final String VIEW_ALL = "subcontract:view:all";

    public SubcontractDocumentAccessPolicy(OwnerVisibility ownerVisibility,
                                           SecurityContextCurrentUser currentUser) {
        super(SCOPE, VIEW_ALL, ownerVisibility, currentUser);
    }

    @Override
    public NativeReadScope materialIssueReadScope(String documentAlias,String parameterName) {
        if(documentAlias==null||!documentAlias.matches("[a-zA-Z_][a-zA-Z0-9_]*"))throw new IllegalArgumentException("Invalid material issue query alias");
        NativeReadScope owner=nativeReadScope(documentAlias+".maker_id",parameterName);
        if(!hasAuthority("subcontract_outbound:view"))return owner;
        return new NativeReadScope("("+owner.predicate()+" OR "+documentAlias+".owner_pool='"+
                com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue.POOL_WAREHOUSE_OUTBOUND+"')",owner.parameterName(),owner.owners());
    }
}
