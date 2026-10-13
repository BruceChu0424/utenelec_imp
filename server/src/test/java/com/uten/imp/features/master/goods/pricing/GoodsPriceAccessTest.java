package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.security.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsPriceAccessTest {
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void analyticsGrantCannotBypassSourcePricePermission(){
        var a=access(Set.of("goods:view",GoodsPriceAccess.VIEW,"purchase_order:view"));
        assertThat(a.available(Kind.PURCHASE)).isFalse();assertThatThrownBy(()->a.require(Kind.PURCHASE)).hasMessageContaining("商业价格");
    }
    @Test void financePricePrivilegeStillRequiresSourceReadAndAnalytics(){
        assertThat(access(Set.of("goods:view",GoodsPriceAccess.VIEW,"finance:view:all")).available(Kind.PURCHASE)).isFalse();
        assertThat(access(Set.of("goods:view",GoodsPriceAccess.VIEW,"finance:view:all","finance_order_approval:view")).available(Kind.PURCHASE)).isTrue();
    }
    @Test void salesPricesAreNotImpliedByProcurementOrFinancePrices(){
        assertThat(access(Set.of("goods:view",GoodsPriceAccess.VIEW,"sales_order:view","finance:view:all")).available(Kind.SALES)).isFalse();
        assertThat(access(Set.of("goods:view",GoodsPriceAccess.VIEW,"sales_order:view","sales_order:price:view")).available(Kind.SALES)).isTrue();
    }
    @Test void nullOwnerDoesNotBecomePublic(){
        var p=new org.springframework.jdbc.core.namedparam.MapSqlParameterSource();
        String predicate=GoodsPriceSourceReader.ownerClause(new OwnerVisibility.OwnerScope(false,Set.of(UUID.randomUUID())),p);
        assertThat(predicate).contains("owner_employee_id IN").doesNotContain("IS NULL");
        assertThat(GoodsPriceSourceReader.ownerClause(new OwnerVisibility.OwnerScope(false,Set.of()),p)).contains("1=0");
    }
    @Test void financeQuoteHistoryDoesNotImplySalesOrderPrices(){
        var a=access(Set.of("goods:view",GoodsPriceAccess.VIEW,"sales_quote_finance:view"));
        a.requireHistory(Kind.SALES);assertThat(a.available(Kind.SALES)).isFalse();assertThatThrownBy(()->a.require(Kind.SALES)).hasMessageContaining("商业价格");
        var pageOnly=access(Set.of("goods:view",GoodsPriceAccess.VIEW,"sales_quote:view"));
        assertThatThrownBy(()->pageOnly.requireHistory(Kind.SALES)).hasMessageContaining("商业价格");
    }
    private GoodsPriceAccess access(Set<String> permissions){
        var current=mock(SecurityContextCurrentUser.class);var user=mock(AuthUser.class);when(user.getPermissions()).thenReturn(permissions);when(current.get()).thenReturn(Optional.of(user));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("actor","",permissions.stream().map(SimpleGrantedAuthority::new).toList()));
        return new GoodsPriceAccess(current,mock(OwnerVisibility.class));
    }
}
