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
        return has("goods:view")&&has(VIEW)&&canReadSources(kind)&&canReadPrices(kind);
    }
    void require(Kind kind) {
        CurrentAuthorityGuard.requireAll("goods:view",VIEW);
        if(kind==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择价格类型");
        if(!canReadSources(kind)||!canReadPrices(kind))throw new ApiException(ErrorCode.FORBIDDEN,"无此类来源单据或商业价格查看权限");
    }
    void requireHistory(Kind kind) {
        CurrentAuthorityGuard.requireAll("goods:view",VIEW);
        if(kind==Kind.SALES&&has("sales_quote_finance:view"))return;
        require(kind);
    }
    boolean has(String permission){return current.get().map(a->a.isSuperAdmin()||a.getPermissions().contains(permission)).orElse(false);}
    private boolean canReadSources(Kind kind){return has(kind.name().toLowerCase()+"_order:view")||kind!=Kind.SALES&&has("finance_order_approval:view");}
    private boolean canReadPrices(Kind kind){return has(kind.name().toLowerCase()+"_order:price:view")||kind!=Kind.SALES&&has("finance:view:all");}
    OwnerVisibility.OwnerScope sourceScope(Kind kind){String scope=kind.name().toLowerCase();return owners.evaluate(scope,scope+":view:all");}
}
