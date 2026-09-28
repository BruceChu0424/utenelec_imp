package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort.ClientCandidate;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientCandidateQuery;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientSignal;
import com.uten.imp.features.sales.intake.IntakePricing.CandidatePricing;
import com.uten.imp.features.sales.intake.IntakePricing.CurrencyInfo;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class IntakePricingAndClientTest {

    private static final CurrencyInfo RMB = new CurrencyInfo("CNY", UUID.randomUUID(), "人民币", false, null, "人民币");
    private static final CurrencyInfo USD = new CurrencyInfo("USD", UUID.randomUUID(), "人民币", true, new BigDecimal("7.1"), "美元");
    private static final CurrencyInfo USD_NO_RATE = new CurrencyInfo("USD", UUID.randomUUID(), "人民币", true, null, "美元");

    private static CandidatePricing price(String customer, String list, CurrencyInfo currency) {
        return IntakePricing.price(customer == null ? null : new BigDecimal(customer), list == null ? null : new BigDecimal(list),
                currency);
    }

    @Test
    void baseCurrencyDiscountComesFromMoneyPolicy() {
        CandidatePricing exact = price("21", "21", RMB);
        assertThat(exact.flag()).isEqualTo("OK");
        assertThat(exact.discount()).isEqualByComparingTo("1.0000");
        assertThat(exact.rateUsed()).isEqualByComparingTo("1");
        CandidatePricing rounded = price("10", "30", RMB);
        assertThat(rounded.flag()).isEqualTo("ROUNDED");
        assertThat(rounded.discount()).isEqualByComparingTo("0.3333");
        assertThat(price("5", "30", RMB).flag()).isEqualTo("OUT_OF_RANGE");
        assertThat(price("22.11", "21", RMB).flag()).isEqualTo("ABOVE_LIST");
        assertThat(price("22.11", "21", RMB).discount()).isNull();
        assertThat(price("1", "0", RMB).flag()).isEqualTo("NO_LIST_PRICE");
        assertThat(price("1", null, RMB).blocking()).isTrue();
        assertThat(price(null, "21", RMB).flag()).isNull();
    }

    @Test
    void rangeIsJudgedOnTheRoundedDiscountLikeTheMaskedSavePath() {
        // 30.004 / 100 取 4 位是 0.3000: 不在 (0.3, 1], 与看不到价格的人保存时的反推一致(不给折扣)。
        CandidatePricing floor = price("30.004", "100", RMB);
        assertThat(floor.flag()).isEqualTo("OUT_OF_RANGE");
        assertThat(floor.discount()).isNull();
        assertThat(com.uten.imp.features.sales.SalesPriceAuthority.deriveDiscountFromClientPrice(
                new BigDecimal("30.004"), null, new BigDecimal("100"))).isEmpty();
        // 100.004 / 100 取 4 位是 1.0000: 按 1 折导入, 不当成「高于标价」拦下, 保存路径同样得 1。
        CandidatePricing ceiling = price("100.004", "100", RMB);
        assertThat(ceiling.flag()).isEqualTo("ROUNDED");
        assertThat(ceiling.discount()).isEqualByComparingTo("1");
        assertThat(ceiling.blocking()).isFalse();
        assertThat(com.uten.imp.features.sales.SalesPriceAuthority.deriveDiscountFromClientPrice(
                new BigDecimal("100.004"), null, new BigDecimal("100"))).hasValueSatisfying(
                d -> assertThat(d).isEqualByComparingTo("1"));
    }

    @Test
    void foreignFileTriesBothRatesAndOnlyUsesAnUnambiguousOne() {
        CandidatePricing converted = price("2.8", "21", USD);
        assertThat(converted.flag()).isEqualTo("ROUNDED");
        assertThat(converted.rateUsed()).isEqualByComparingTo("7.1");
        assertThat(converted.discount()).isEqualByComparingTo("0.9467");
        CandidatePricing directRmb = price("18", "21", USD);
        assertThat(directRmb.rateUsed()).isEqualByComparingTo("1");
        assertThat(directRmb.note()).contains("没有按汇率换算");
        CurrencyInfo hkd = new CurrencyInfo("HKD", UUID.randomUUID(), "人民币", true, new BigDecimal("0.92"), "港币");
        CandidatePricing ambiguous = price("0.9", "1", hkd);
        assertThat(ambiguous.flag()).as("both readings plausible").isEqualTo("AMBIGUOUS_CURRENCY");
        assertThat(ambiguous.discount()).isNull();
        assertThat(price("1", "100", USD).flag()).isEqualTo("OUT_OF_RANGE");
        assertThat(price("30", "21", USD).flag()).isEqualTo("ABOVE_LIST");
    }

    @Test
    void missingFinanceRateIsReportedNotGuessed() {
        assertThat(price("2.8", "21", USD_NO_RATE).flag()).isEqualTo("RATE_MISSING");
        assertThat(price("2.8", "21", USD_NO_RATE).note()).contains("参考汇率未维护");
        assertThat(price("18", "21", USD_NO_RATE).flag()).isEqualTo("ROUNDED");
        assertThat(USD_NO_RATE.rateMissing()).isTrue();
    }

    @Test
    void clientQueryUsesDistinctiveTokensAndSkipsFreeMail() {
        IntakeHeader h = new IntakeHeader();
        h.buyerName = "SUNAS ELECTRICAL RESOURCE LTD.";
        h.addEmail("sunasinv40@gmail.com");
        h.addEmail("buyer@sunas-group.com");
        h.addPhone("+234 803 123 4567");
        h.country = "尼日利亚";
        ClientCandidateQuery q = ClientMatcher.query(h);
        assertThat(q.distinctiveTokens()).containsExactly("SUNAS");
        assertThat(q.emailDomains()).containsExactly("sunas-group.com");
        assertThat(q.emails()).contains("sunasinv40@gmail.com");
        assertThat(q.phoneLast8()).containsExactly("31234567");
        assertThat(q.placeIds()).contains("尼日利亚");
        assertThat(ClientMatcher.distinctiveTokens("ALDAR FOR ELECTRICAL INDUSTRIES CO. LTD.")).containsExactly("ALDAR");
    }

    private static ClientCandidate candidate(UUID id, String name, Set<ClientSignal> signals) {
        return new ClientCandidate(id, "C", name, null, null, null, signals, Set.of("SUNAS"), 0);
    }

    @Test
    void strongSignalAutoSelectsAndBasketAddsConfidence() {
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        UUID g1 = UUID.randomUUID();
        UUID g2 = UUID.randomUUID();
        List<Set<UUID>> lines = List.of(Set.of(g1), Set.of(g2));
        ClientMatcher.Result r = ClientMatcher.match(List.of(candidate(a, "尼日利亚SUNAS", Set.of(ClientSignal.TOKEN))),
                Map.of(a, Set.of(g1, g2), b, Set.of(g1)), lines, null, 18, null);
        assertThat(r.status()).isEqualTo("MATCHED");
        assertThat(r.selectedClientId()).isEqualTo(a);
        assertThat(r.ranked().getFirst().reasons).contains("名称里有「SUNAS」", "文件里的货品该客户都买过");
    }

    @Test
    void basketOnlyEvidencePreselectsButNeverAutoSelects() {
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        List<Set<UUID>> lines = List.of(Set.of(UUID.randomUUID()), Set.of(UUID.randomUUID()), Set.of(UUID.randomUUID()),
                Set.of(UUID.randomUUID()));
        Set<UUID> all = lines.stream().flatMap(Set::stream).collect(java.util.stream.Collectors.toSet());
        ClientMatcher.Result r = ClientMatcher.match(List.of(), Map.of(a, all, b, Set.of(lines.getFirst().iterator().next())),
                lines, null, 18, null);
        assertThat(r.status()).isEqualTo("REVIEW");
        assertThat(r.selectedClientId()).isEqualTo(a);
        ClientMatcher.Result close = ClientMatcher.match(List.of(), Map.of(a, all, b, all), lines, null, 18, null);
        assertThat(close.status()).as("no basket winner without a 0.25 margin").isEqualTo("UNMATCHED");
    }

    @Test
    void placeOnlyIsReviewAndNoVisibleClientsIsReported() {
        UUID a = UUID.randomUUID();
        ClientMatcher.Result place = ClientMatcher.match(List.of(candidate(a, "约旦二", Set.of(ClientSignal.PLACE))), Map.of(),
                List.of(), null, 5, "约旦");
        assertThat(place.status()).isEqualTo("REVIEW");
        assertThat(place.ranked().getFirst().reasons).containsExactly("国家/地区一致(约旦)");
        assertThat(ClientMatcher.match(List.of(), Map.of(), List.of(), null, 0, null).status()).isEqualTo("NO_VISIBLE_CLIENTS");
        assertThat(ClientMatcher.match(List.of(), Map.of(), List.of(), null, 3, null).status()).isEqualTo("UNMATCHED");
    }

    @Test
    void preselectedClientStaysButStrongOtherBuyerIsFlagged() {
        UUID mine = UUID.randomUUID();
        UUID other = UUID.randomUUID();
        ClientMatcher.Result r = ClientMatcher.match(List.of(new ClientCandidate(other, "C9", "其他客户", null, null, null,
                        Set.of(ClientSignal.EMAIL), Set.of(), 0)), Map.of(), List.of(), mine, 10, null);
        assertThat(r.status()).isEqualTo("PRESET");
        assertThat(r.selectedClientId()).isEqualTo(mine);
        assertThat(r.strongOther().clientId).isEqualTo(other);
    }
}
