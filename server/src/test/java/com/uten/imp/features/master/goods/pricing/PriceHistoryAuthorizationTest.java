package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceHistoryTableContracts.*;

class PriceHistoryAuthorizationTest {
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void tableAndRemoteFacetsDenyUnauthorizedPoolsBeforeReadingAnyRecordsOrTotals() {
        for(Kind kind:Kind.values()) {
            String prefix=kind.name().toLowerCase(Locale.ROOT)+"_order";
            var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"scope-only",
                    Set.of("goods:view","goods:price_analysis:view",prefix+":view",prefix+":edit","finance:view:all"),false,true,false);
            var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(user));
            SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(user,null,user.getAuthorities()));
            var db=mock(NamedParameterJdbcTemplate.class);var refs=mock(MasterReferenceValidationPort.class);var source=mock(GoodsPriceSourceReader.class);
            var service=new GoodsPriceHistoryTableService(db,new GoodsPriceAccess(current,mock(OwnerVisibility.class)),refs,source);
            var query=new Query(UUID.randomUUID(),kind,null,null,null,null,null,null,null,null,null,null,null,null);
            var table=new TableQuery(query,null,null,1,50,null,null,Map.of());
            assertThatThrownBy(()->service.table(table)).isInstanceOf(ApiException.class);
            assertThatThrownBy(()->service.facets(new FacetQuery(table,"unitPrice",null,1,50))).isInstanceOf(ApiException.class);
            verifyNoInteractions(db,refs,source);
        }
    }
}
