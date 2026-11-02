package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;

@Component
@RequiredArgsConstructor
final class GoodsPriceAccess {
    static final String VIEW="goods:price_analysis:view";
    private final SecurityContextCurrentUser current;
    private final OwnerVisibility owners;
    boolean available(Kind kind) {
        if(kind==null)return false;
        return current.get().map(user->PriceAnalysisAccessPolicy.canAnalyze(user.getPermissions(),user.isSuperAdmin(),kind.name())).orElse(false);
    }
    void require(Kind kind) {
        CurrentAuthorityGuard.requireAll("goods:view",VIEW);
        if(kind==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择价格类型");
        if(!available(kind))throw new ApiException(ErrorCode.FORBIDDEN,"无此类来源单据或商业价格查看权限");
    }
    void requireHistory(Kind kind) {
        CurrentAuthorityGuard.requireAll("goods:view",VIEW);
        if(kind==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择价格类型");
        if(!current.get().map(user->PriceAnalysisAccessPolicy.canReadHistory(user.getPermissions(),user.isSuperAdmin(),kind.name())).orElse(false))
            throw new ApiException(ErrorCode.FORBIDDEN,"无此类来源单据或商业价格查看权限");
    }
    boolean has(String permission){return current.get().map(a->a.isSuperAdmin()||a.getPermissions().contains(permission)).orElse(false);}
    OwnerVisibility.OwnerScope sourceScope(Kind kind){String scope=kind.name().toLowerCase();return owners.evaluate(scope,scope+":view:all");}
}
