package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.security.AuthUser;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.context.annotation.*;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MarketPriceSecurityTest {
    @Configuration @EnableMethodSecurity(proxyTargetClass=true)
    static class Config {
        @Bean GoodsMarketReferenceService service(){return mock(GoodsMarketReferenceService.class);}
        @Bean AuditDetailViewRecorder audit(){return mock(AuditDetailViewRecorder.class);}
        @Bean GoodsMarketReferenceController controller(GoodsMarketReferenceService service,AuditDetailViewRecorder audit){return new GoodsMarketReferenceController(service,audit);}
    }
    @Test void sharedMarketReadAndWriteAnnotationsDenyScopeOnlyBeforeEnteringTheService() {
        try(var context=new AnnotationConfigApplicationContext(Config.class)) {
            var service=context.getBean(GoodsMarketReferenceService.class);
            var controller=context.getBean(GoodsMarketReferenceController.class);UUID id=UUID.randomUUID();
            Set<String> grants=Set.of("goods:view","goods:edit","goods:price_analysis:view","purchase_order:view","finance:view:all");
            login(grants);
            assertThatThrownBy(()->controller.get(id)).isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(()->controller.catalog(id)).isInstanceOf(AccessDeniedException.class);
            assertThatThrownBy(()->controller.put(id,new MaterialForecastContracts.BindingRequest(null,0L))).isInstanceOf(AccessDeniedException.class);
            verifyNoInteractions(service);
            var allowed=new HashSet<>(grants);allowed.add("purchase_order:price:view");login(allowed);
            controller.get(id);verify(service).get(id);
        } finally {SecurityContextHolder.clearContext();}
    }
    private static void login(Set<String> grants) {
        var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"market-scope",grants,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(user,null,user.getAuthorities()));
    }
}
