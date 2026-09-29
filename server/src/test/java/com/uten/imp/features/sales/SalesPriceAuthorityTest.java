package com.uten.imp.features.sales;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** ADR-134 销售单价权威: 预览价校验、折扣规范、文件单价反推折扣(币种规则)、既有行配对。 */
class SalesPriceAuthorityTest {

    @Test
    void previewPriceMustEqualAuthorityAndPendingPriceAcceptsNoPreview() {
        assertThatCode(() -> SalesPriceAuthority.requirePreviewMatches(null, null, "报价"))
                .doesNotThrowAnyException();
        assertThatCode(() -> SalesPriceAuthority.requirePreviewMatches(
                new BigDecimal("6.2500"), new BigDecimal("6.25"), "报价")).doesNotThrowAnyException();
        assertThatThrownBy(() -> SalesPriceAuthority.requirePreviewMatches(
                new BigDecimal("6.24"), new BigDecimal("6.25"), "报价"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("报价单价已变化")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
        // 待财务定价(权威价为空)时页面不能带价格: 带了就是改包。
        assertThatThrownBy(() -> SalesPriceAuthority.requirePreviewMatches(
                BigDecimal.ONE, null, "报价"))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void discountsAreFourDecimalMultipliersAndFinanceMustStateOne() {
        assertThat(SalesPriceAuthority.normalizeDiscountForWrite(null)).isEqualByComparingTo("1");
        assertThat(SalesPriceAuthority.normalizeDiscountForWrite(BigDecimal.ZERO)).isEqualByComparingTo("1");
        assertThat(SalesPriceAuthority.normalizeDiscountForWrite(new BigDecimal("0.95")).scale()).isEqualTo(4);
        assertThatThrownBy(() -> SalesPriceAuthority.normalizeDiscountForWrite(new BigDecimal("1.01")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SalesPriceAuthority.normalizeDiscountForWrite(new BigDecimal("0.12345")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SalesPriceAuthority.normalizeExplicitDiscount(null))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SalesPriceAuthority.normalizeExplicitDiscount(BigDecimal.ZERO))
                .isInstanceOf(ApiException.class);
        assertThat(SalesPriceAuthority.plausibleDiscount(new BigDecimal("0.3"))).isFalse();
        assertThat(SalesPriceAuthority.plausibleDiscount(new BigDecimal("0.3001"))).isTrue();
        assertThat(SalesPriceAuthority.plausibleDiscount(BigDecimal.ONE)).isTrue();
        assertThat(SalesPriceAuthority.plausibleDiscount(null)).isFalse();
    }

    @Test
    void negativeMasterPriceIsRejectedButQuotesAcceptAMissingOne() {
        assertThat(SalesPriceAuthority.requireNonNegativePrice(null)).isNull();
        assertThatThrownBy(() -> SalesPriceAuthority.requireNonNegativePrice(new BigDecimal("-1")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SalesPriceAuthority.requireMasterPrice(UUID.randomUUID(), null, "销售订货"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未维护销售单价");
    }

    @Test
    void currencySpellingsCollapseToOneCode() {
        assertThat(SalesPriceAuthority.canonicalCurrency(" us$ ")).isEqualTo("USD");
        assertThat(SalesPriceAuthority.canonicalCurrency("美金")).isEqualTo("USD");
        assertThat(SalesPriceAuthority.canonicalCurrency("RMB")).isEqualTo("CNY");
        assertThat(SalesPriceAuthority.canonicalCurrency("人民币")).isEqualTo("CNY");
        assertThat(SalesPriceAuthority.canonicalCurrency("港币")).isEqualTo("HKD");
        assertThat(SalesPriceAuthority.canonicalCurrency("  ")).isNull();
        assertThat(SalesPriceAuthority.canonicalCurrency("SOMETHINGLONG")).hasSize(8);
    }

    @Test
    void baseCurrencyFileUsesThePlainRatioOnly() {
        SalesPriceAuthority authority = new SalesPriceAuthority(currencies());
        // 人民币文件: 9 ÷ 10 = 0.9。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("9"), authority.resolveFileCurrency("RMB"), BigDecimal.TEN))
                .contains(new BigDecimal("0.9000"));
        // 没写币种按本位币; 超出合理区间(0.1)推不出。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(BigDecimal.ONE, authority.resolveFileCurrency(null), BigDecimal.TEN)).isEmpty();
        // 高于标价推不出(绝不截成 1)。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("11"), authority.resolveFileCurrency(null), BigDecimal.TEN)).isEmpty();
        // 没有标价推不出。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("9"), authority.resolveFileCurrency(null), null)).isEmpty();
    }

    @Test
    void foreignFileUsesTheOnlyPlausibleOfPlainAndFinanceRate() {
        SalesPriceAuthority authority = new SalesPriceAuthority(currencies());
        // 美元 9, 标价 70: 按 1 → 0.1286(不合理); 按财务汇率 7 → 0.9 → 用 0.9。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("9"), authority.resolveFileCurrency("USD"), new BigDecimal("70")))
                .contains(new BigDecimal("0.9000"));
        // 美元 9, 标价 10: 按 1 → 0.9(合理); 按 7 → 6.3(高于标价) → 用 0.9(按美元标价)。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("9"), authority.resolveFileCurrency("USD"), BigDecimal.TEN))
                .contains(new BigDecimal("0.9000"));
        // 两种都不合理: 美元 5, 标价 20 → 按 1 为 0.25(太低) / 按 7 为 1.75(高于标价) → 推不出。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("5"), authority.resolveFileCurrency("USD"), new BigDecimal("20")))
                .isEmpty();
        // 汇率没维护(港币 0): 只看按 1 的比值。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("9"), authority.resolveFileCurrency("HKD"), BigDecimal.TEN))
                .contains(new BigDecimal("0.9000"));
        // 美元 12, 标价 100: 按 1 为 0.12(太低) / 按 7 为 0.84 → 只有一个合理 → 用 0.84。
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("12"), authority.resolveFileCurrency("USD"), new BigDecimal("100")))
                .contains(new BigDecimal("0.8400"));
        SalesPriceAuthority unitRate = new SalesPriceAuthority(currencies("1.000000"));
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("9"), unitRate.resolveFileCurrency("USD"), BigDecimal.TEN))
                .as("汇率恰为 1 时两种比值相同, 都合理即不猜")
                .isEmpty();
    }

    @Test
    void fileCurrencyIsResolvedOnceAndDerivingNeverQueriesTheDatabase() {
        EntityManager em = currencies();
        SalesPriceAuthority authority = new SalesPriceAuthority(em);
        SalesPriceAuthority.FileCurrency usd = authority.resolveFileCurrency("US$");
        assertThat(usd.base()).isFalse();
        assertThat(usd.financeRate()).isEqualByComparingTo("7");
        for (int line = 0; line < 50; line++) {
            assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(
                    new BigDecimal("9"), usd, new BigDecimal("70"))).contains(new BigDecimal("0.9000"));
        }
        // 50 行只查一次币种资料(每次保存解析一次, 逐行反推不再查库)。
        verify(em, times(1)).createNativeQuery(anyString());
        // 没写币种: 不查库, 按本位币。
        EntityManager untouched = mock(EntityManager.class);
        assertThat(new SalesPriceAuthority(untouched).resolveFileCurrency("  ").base()).isTrue();
        verifyNoInteractions(untouched);
        assertThat(SalesPriceAuthority.deriveDiscountFromClientPrice(new BigDecimal("9"), null, BigDecimal.TEN))
                .as("文件币种未解析(空)按本位币").contains(new BigDecimal("0.9000"));
    }

    @Test
    void existingLinesPairByUuidThenByIdentityAndOnlyOnce() {
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        Stored first = new Stored(UUID.randomUUID(), goods, unit, "1.000000");
        Stored second = new Stored(UUID.randomUUID(), goods, unit, "1");
        var book = new SalesPriceAuthority.ExistingPriceBook<Stored, Line>(
                List.of(first, second), Stored::id,
                s -> SalesPriceAuthority.identity(s.goods(), null, s.unit(), new BigDecimal(s.rate())),
                Line::id,
                l -> SalesPriceAuthority.identity(l.goods(), null, l.unit(), new BigDecimal(l.rate())));
        assertThat(book.take(new Line(second.id(), goods, unit, "1"))).isSameAs(second);
        assertThat(book.take(new Line(second.id(), goods, unit, "1"))).as("同一行只配一次").isNull();
        assertThat(book.take(new Line(null, goods, unit, "1.0"))).as("无 id 按身份兜底").isSameAs(first);
        assertThat(book.take(new Line(null, goods, unit, "1"))).isNull();
        assertThat(book.unconsumed(List.of(first, second))).isEmpty();
        var changed = new SalesPriceAuthority.ExistingPriceBook<Stored, Line>(
                List.of(first), Stored::id,
                s -> SalesPriceAuthority.identity(s.goods(), null, s.unit(), new BigDecimal(s.rate())),
                Line::id,
                l -> SalesPriceAuthority.identity(l.goods(), null, l.unit(), new BigDecimal(l.rate())));
        assertThat(changed.take(new Line(first.id(), UUID.randomUUID(), unit, "1")))
                .as("换了货品的同一行 id 不沿用冻结价").isNull();
        assertThat(changed.unconsumed(List.of(first))).containsExactly(first);
    }

    private record Stored(UUID id, UUID goods, UUID unit, String rate) {
    }

    private record Line(UUID id, UUID goods, UUID unit, String rate) {
    }

    private static EntityManager currencies() {
        return currencies("7.000000");
    }

    /** 币种资料: 人民币(本位币) / 美金(汇率 usdRate) / 港币(汇率 0 = 未维护)。 */
    private static EntityManager currencies(String usdRate) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(
                new Object[]{"001", "人民币", new BigDecimal("1.000000"), true},
                new Object[]{"002", "美金", new BigDecimal(usdRate), false},
                new Object[]{"003", "港币", new BigDecimal("0.000000"), false}));
        return em;
    }
}
