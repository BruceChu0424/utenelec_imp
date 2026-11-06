package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.*;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.math.BigDecimal;
import java.util.*;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterSummaryReadSupportTest {
    private final ObjectMapper json = new ObjectMapper();
    private final VersionedSummaryPages pages = mock(VersionedSummaryPages.class);
    private final List<VersionedSummaryPages.Request> proofs = new ArrayList<>();
    private final MasterSummaryReadSupport support = new MasterSummaryReadSupport(pages, json);
    record Row(String id, BigDecimal amount) { }
    @BeforeEach void setup() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader", "unused",
                List.of(new SimpleGrantedAuthority("client:view"),new SimpleGrantedAuthority("supplier:view"),new SimpleGrantedAuthority("mould:view"))));
        when(pages.read(any(),any(Runnable.class),any())).thenAnswer(call->{
            proofs.add(call.getArgument(0));call.getArgument(1,Runnable.class).run();
            return new VersionedSummaryPages.Snapshot<>(call.getArgument(2,Supplier.class).get(),"a".repeat(64),"b".repeat(64),"c".repeat(64));
        });
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void typedRowsAndOriginalFilterArePassedThroughWithoutMonetaryConversion() {
        var filter=json.convertValue(Map.of("credit",new BigDecimal("9007199254740993.123456789000"),
                "excludeLegacyFinanceStub",true,"selectableOnly",true),ClientQueryFilter.class);
        var row=new Row("same-object",new BigDecimal("9007199254740993.123456789000"));
        var result=support.read("client-master-list","client","client:view",
                new MasterSummaryReadSupport.Query<>(filter,2,100,"credit","desc"),"b".repeat(64),(actual,page,size,sort,order)->{
                    assertThat(actual).isSameAs(filter);assertThat(actual.excludeLegacyFinanceStub()).isTrue();assertThat(actual.selectableOnly()).isTrue();
                    assertThat(List.of(page,size,sort,order)).containsExactly(2,100,"credit","desc");
                    return new PageResponse<>(List.of(row),2,100,101,2);
                });
        assertThat(result.value().items().getFirst()).isSameAs(row);
        assertThat(result.value().total()).isEqualTo(101);
        assertThat(proofs.getFirst().maxReadSize()).isEqualTo(100);
        assertThat(proofs.getFirst().authorizationDomain()).isEqualTo("client");
    }

    @Test void exactMoneyAndOriginalPrecisionChoicesAreBoundIntoTheSnapshotIdentity() throws Exception {
        var canonical=json.copy().enable(com.fasterxml.jackson.databind.SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
        for(String credit:List.of("9007199254740993.123456789000","9007199254740993.123456789001")) {
            var filter=json.convertValue(Map.of("credit",new BigDecimal(credit)),ClientQueryFilter.class);
            support.read("client-master-list","client","client:view",new MasterSummaryReadSupport.Query<>(filter,1,100,null,null),null,
                    (f,p,n,s,o)->new PageResponse<Row>(List.of(),1,100,0,0));
        }
        String first=canonical.writeValueAsString(proofs.get(0).queryIdentity());
        String second=canonical.writeValueAsString(proofs.get(1).queryIdentity());
        assertThat(first).contains("9007199254740993.123456789000");assertThat(first).isNotEqualTo(second);
        try(var ignored=BusinessPrecisionContext.use(Map.of("subcontract.loss-summary.percent",new BusinessPrecisionContext.Choice(6,"DOWN")))) {
            support.read("supplier-master-list","supplier","supplier:view",new MasterSummaryReadSupport.Query<>(Map.of(),1,100,null,null),null,
                    (f,p,n,s,o)->new PageResponse<Row>(List.of(),1,100,0,0));
        }
        assertThat(canonical.writeValueAsString(proofs.get(2).queryIdentity())).contains("subcontract.loss-summary.percent","DOWN","6");
    }

    @Test void continuationNeedsTheRealInitialRevisionAndOrdinaryReadCapIsNotExpanded() {
        for(var query:List.of(new MasterSummaryReadSupport.Query<>(Map.of(),2,100,null,null),
                new MasterSummaryReadSupport.Query<>(Map.of(),1,101,null,null)))
            assertThatThrownBy(()->support.read("client-master-list","client","client:view",query,null,
                    (f,p,n,s,o)->new PageResponse<Row>(List.of(),p,n,0,0))).isInstanceOf(ApiException.class);
        assertThat(proofs).isEmpty();
    }

    @Test void aTruncatedPageCannotBeClaimedCompleteAndEachOwningPermissionIsChecked() {
        assertThatThrownBy(()->support.read("mould-master-list","master_mould","mould:view",
                new MasterSummaryReadSupport.Query<>(Map.of(),1,100,null,null),null,
                (f,p,n,s,o)->new PageResponse<Row>(List.of(),1,100,2414,25)))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.PRIMARY_UNAVAILABLE));
        SecurityContextHolder.clearContext();
        assertThatThrownBy(()->support.read("supplier-master-list","supplier","supplier:view",
                new MasterSummaryReadSupport.Query<>(Map.of(),1,100,null,null),null,
                (f,p,n,s,o)->new PageResponse<Row>(List.of(),1,100,0,0)))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
}
