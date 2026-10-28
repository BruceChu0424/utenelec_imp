package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.web.ApiException;
import java.time.OffsetDateTime;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class GoodsCostVersionQueryTest {
    private final UUID currency=UUID.randomUUID();
    private GoodsCostContracts.VersionSummary row(UUID denomination,String total,OffsetDateTime at) {
        return new GoodsCostContracts.VersionSummary(UUID.randomUUID(),UUID.randomUUID(),null,"采购 旧版_%","DRAFT",
                9007199254740993L,"9007199254740993.0001",total,null,"PARTIAL",null,at,
                denomination,"历史美金",UUID.randomUUID(),"历史件");
    }
    @Test void exactFactsAndChineseCalendarPeriodsKeepTheStoredNamesAndPrecision() {
        var query=new GoodsCostVersionQuery(Map.of("name","采购 旧版_%","version",">9007199254740992",
                "batchQty","9007199254740993.0001","knownTotal",">=0.1234567890123456789",
                "updatedAt","2026-10-28","currencyName","历史 美金","unitName","历史 件"),
                "DRAFT",currency.toString(),"knownTotal","desc");
        var first=row(currency,"0.1234567890123456789",OffsetDateTime.parse("2026-10-27T16:00:00Z"));
        assertThat(query.matches(first,false)).isTrue();
        assertThat(first.versionExact()).isEqualTo("9007199254740993");
        assertThat(query.matches(row(currency,"0.1234567890123456788",first.updatedAt()),false)).isFalse();
        assertThat(query.matches(row(currency,first.knownTotal(),first.updatedAt().minusNanos(1)),false)).isFalse();
        assertThat(query.matches(row(currency,first.knownTotal(),first.updatedAt().plusDays(1)),false)).isFalse();
        assertThat(query.ordering()).contains("::numeric", "DESC NULLS LAST");
    }
    @Test void currencyCandidatesExcludeTheirOwnSelectionAndDependentMoneyWithoutTreatingUnknownAsZero() {
        var query=new GoodsCostVersionQuery(Map.of("knownTotal","!=0"),null,currency.toString(),null,null);
        var unknown=row(currency,null,OffsetDateTime.now());
        assertThat(query.matches(unknown,false)).isFalse();
        assertThat(query.matches(unknown,true)).isTrue();
        var other=row(UUID.randomUUID(),"100",OffsetDateTime.now());
        assertThat(query.matches(other,false)).isFalse();assertThat(query.matches(other,true)).isTrue();
        assertThat(new GoodsCostVersionQuery(Map.of(),null,"__null__",null,null)
                .matches(row(null,null,OffsetDateTime.now()),false)).isTrue();
    }
    @Test void moneyAndSortControlsCannotBypassCurrencyOrFixedFieldContracts() {
        for(String currencyFilter:Arrays.asList(null,"__null__")) {
            assertThatThrownBy(()->new GoodsCostVersionQuery(Map.of("knownTotal",">0"),null,currencyFilter,null,null)).isInstanceOf(ApiException.class);
            assertThatThrownBy(()->new GoodsCostVersionQuery(Map.of(),null,currencyFilter,"knownTotal","asc")).isInstanceOf(ApiException.class);
        }
        assertThatThrownBy(()->new GoodsCostVersionQuery(Map.of("sourcePrivatePrice","1"),null,null,null,null)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->new GoodsCostVersionQuery(Map.of(),"ARCHIVED",null,null,null)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->new GoodsCostVersionQuery(Map.of(),null,null,"name;DROP TABLE goods","asc")).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->new GoodsCostVersionQuery(Map.of("updatedAt","2026-02-30"),null,null,null,null)).isInstanceOf(ApiException.class);
    }
}
