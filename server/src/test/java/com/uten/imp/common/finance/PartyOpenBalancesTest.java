package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-128: 按单据币种派生余额视图与额度比较只在这里算一次。 */
class PartyOpenBalancesTest {

    private static final UUID CNY = UUID.randomUUID();
    private static final UUID USD = UUID.randomUUID();
    private static final UUID HKD = UUID.randomUUID();
    private static final UUID CLIENT = UUID.randomUUID();

    private static PartyOpenBalances balances() {
        return new PartyOpenBalances(
                Map.of(CNY, new PartyOpenBalances.Currency(CNY, "人民币", true),
                        USD, new PartyOpenBalances.Currency(USD, "美金", false),
                        HKD, new PartyOpenBalances.Currency(HKD, "港币", false)),
                Map.of(CLIENT, new PartyOpenBalances.Party(List.of(
                        new PartyOpenBalances.CurrencyAmounts(USD, new BigDecimal("0"),
                                new BigDecimal("200.0000"), new BigDecimal("1400.0000")),
                        new PartyOpenBalances.CurrencyAmounts(HKD, new BigDecimal("50"),
                                BigDecimal.ZERO, BigDecimal.ZERO),
                        new PartyOpenBalances.CurrencyAmounts(CNY, new BigDecimal("30000"),
                                BigDecimal.ZERO, BigDecimal.ZERO)),
                        new BigDecimal("30350"), new BigDecimal("900"), 2)));
    }

    @Test
    void prepaymentSurplusIsANegativeNetInTheDocumentCurrencyAndOtherCurrenciesStaySeparate() {
        PartyOpenBalanceView view = balances().forDocument(CLIENT, USD, null);

        assertThat(view.currencyName()).isEqualTo("美金");
        assertThat(view.baseCurrency()).isFalse();
        assertThat(view.openOriginal()).isEqualByComparingTo("0");
        assertThat(view.creditOriginal()).isEqualByComparingTo("200");
        assertThat(view.netOriginal()).isEqualByComparingTo("-200");
        assertThat(view.creditBookLocal()).isEqualByComparingTo("1400");
        assertThat(view.baseCurrencyName()).isEqualTo("人民币");
        // 本位币排在前面, 其余按名称; 各用自己的币种, 不换算。
        assertThat(view.otherCurrencies()).extracting(PartyOpenBalanceView.CurrencyBalance::currencyName)
                .containsExactly("人民币", "港币");
        assertThat(view.otherCurrencies().getFirst().netOriginal()).isEqualByComparingTo("30000");
        assertThat(view.otherCurrencies().getFirst().baseCurrency()).isTrue();
        assertThat(view.openBookLocal()).isEqualByComparingTo("30350");
        assertThat(view.unverifiedLocal()).isEqualByComparingTo("900");
        assertThat(view.unverifiedCount()).isEqualTo(2);
        assertThat(view.creditLimitLocal()).isNull();
        assertThat(view.overLimitLocal()).isNull();
        assertThat(view.overCredit()).isFalse();
    }

    @Test
    void limitComparisonUsesGrossBookLocalAndKeepsNegativeHeadroom() {
        PartyOpenBalanceView over = balances().forDocument(CLIENT, CNY, new BigDecimal("30000"));
        assertThat(over.overLimitLocal()).isEqualByComparingTo("350");
        assertThat(over.overCredit()).isTrue();

        PartyOpenBalanceView under = balances().forDocument(CLIENT, CNY, new BigDecimal("40000"));
        assertThat(under.overLimitLocal()).isEqualByComparingTo("-9650");
        assertThat(under.overCredit()).isFalse();

        // 铺底额为 0: 超出铺底额 = 全部正式应收(出货财审原口径)。
        PartyOpenBalanceView zeroFloor = balances().forDocument(CLIENT, CNY, BigDecimal.ZERO);
        assertThat(zeroFloor.overLimitLocal()).isEqualByComparingTo("30350");
        assertThat(zeroFloor.overCredit()).isTrue();
    }

    @Test
    void unknownPartyOrMissingCurrencyIsZeroNotAnError() {
        PartyOpenBalanceView nobody = balances().forDocument(UUID.randomUUID(), USD, BigDecimal.TEN);
        assertThat(nobody.currencyName()).isEqualTo("美金");
        assertThat(nobody.netOriginal()).isEqualByComparingTo("0");
        assertThat(nobody.otherCurrencies()).isEmpty();
        assertThat(nobody.overLimitLocal()).isEqualByComparingTo("-10");
        assertThat(nobody.overCredit()).isFalse();

        PartyOpenBalanceView noCurrency = balances().forDocument(CLIENT, null, null);
        assertThat(noCurrency.currencyName()).isNull();
        assertThat(noCurrency.netOriginal()).isEqualByComparingTo("0");
        // 美金只有预收, 也算有余额, 列在其它币种里。
        assertThat(noCurrency.otherCurrencies()).extracting(PartyOpenBalanceView.CurrencyBalance::currencyName)
                .containsExactly("人民币", "港币", "美金");
        assertThat(PartyOpenBalances.empty().forDocument(null, null, null).baseCurrencyName()).isNull();
    }

    @Test
    void moneyIsSerializedAsExactDecimalText() throws Exception {
        String json = new ObjectMapper().writeValueAsString(balances().forDocument(CLIENT, USD, null));
        assertThat(json).contains("\"creditOriginal\":\"200\"", "\"netOriginal\":\"-200\"",
                "\"creditLimitLocal\":null", "\"overCredit\":false", "\"currencyName\":\"美金\"");
    }
}
