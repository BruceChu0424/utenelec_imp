package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 一批往来单位(同一方向: 客户应收或供应商应付)的未结余额, 由
 * {@code application.port.PartyOpenBalancePort} 一次查出(ADR-128)。
 *
 * <p>只保存账面事实(按往来单位 × 币种的原币合计、全币种账面本币毛额、原币未核实部分);
 * 「按哪张单据的币种看、和哪个额度比」由 {@link #forDocument} 统一派生, 各页面不再各算一遍。
 *
 * @param currencies 币种目录(含已停用币种, 仅用于显示名与是否本位币)
 * @param parties    有未结行的往来单位; 查过但没有未结行的单位不在其中, 按零处理
 */
public record PartyOpenBalances(Map<UUID, Currency> currencies, Map<UUID, Party> parties) {

    private static final Party NO_OPEN_ITEMS = new Party(List.of(), BigDecimal.ZERO, BigDecimal.ZERO, 0);

    public PartyOpenBalances {
        currencies = Map.copyOf(currencies);
        parties = Map.copyOf(parties);
    }

    public static PartyOpenBalances empty() {
        return new PartyOpenBalances(Map.of(), Map.of());
    }

    /** 币种目录项。 */
    public record Currency(UUID id, String name, boolean base) {
    }

    /**
     * 一个往来单位在一个币种下的原币合计(已剔除原币未核实的行)。
     *
     * @param openOriginal    应收 / 应付未结原币(含退货红字)
     * @param creditOriginal  可用预收 / 预付 / 贷项原币, 取正数
     * @param creditBookLocal 上一项的账面本币, 取正数
     */
    public record CurrencyAmounts(UUID currencyId, BigDecimal openOriginal,
                                  BigDecimal creditOriginal, BigDecimal creditBookLocal) {
        public CurrencyAmounts {
            Objects.requireNonNull(currencyId, "currencyId");
            openOriginal = nz(openOriginal);
            creditOriginal = nz(creditOriginal);
            creditBookLocal = nz(creditBookLocal);
        }

        boolean hasBalance() {
            return openOriginal.signum() != 0 || creditOriginal.signum() != 0;
        }
    }

    /**
     * 一个往来单位的全部未结事实。
     *
     * @param currencies      按币种的原币合计
     * @param openBookLocal   全币种正式应收 / 应付行的账面本币毛额(信用口径)
     * @param unverifiedLocal 原币未核实行的账面本币合计
     * @param unverifiedCount 原币未核实的行数
     */
    public record Party(List<CurrencyAmounts> currencies, BigDecimal openBookLocal,
                        BigDecimal unverifiedLocal, long unverifiedCount) {
        public Party {
            currencies = List.copyOf(currencies);
            openBookLocal = nz(openBookLocal);
            unverifiedLocal = nz(unverifiedLocal);
        }
    }

    /**
     * 按单据币种派生显示视图, 并和额度比一次。
     *
     * @param partyId          往来单位
     * @param currencyId       单据币种; 为空时单据币种一档为零, 全部币种列入其它币种
     * @param creditLimitLocal 本币额度(信用额度或铺底额); 为空 = 未设置, 不判超额
     */
    public PartyOpenBalanceView forDocument(UUID partyId, UUID currencyId, BigDecimal creditLimitLocal) {
        Party party = partyId == null ? NO_OPEN_ITEMS : parties.getOrDefault(partyId, NO_OPEN_ITEMS);
        CurrencyAmounts document = currencyId == null ? null : party.currencies().stream()
                .filter(amounts -> amounts.currencyId().equals(currencyId))
                .findFirst().orElse(null);
        BigDecimal open = document == null ? BigDecimal.ZERO : document.openOriginal();
        BigDecimal credit = document == null ? BigDecimal.ZERO : document.creditOriginal();
        BigDecimal creditLocal = document == null ? BigDecimal.ZERO : document.creditBookLocal();
        List<PartyOpenBalanceView.CurrencyBalance> others = party.currencies().stream()
                .filter(amounts -> !amounts.currencyId().equals(currencyId))
                .filter(CurrencyAmounts::hasBalance)
                .sorted(Comparator.comparing((CurrencyAmounts amounts) -> !isBase(amounts.currencyId()))
                        .thenComparing(amounts -> Objects.toString(name(amounts.currencyId()), ""))
                        .thenComparing(CurrencyAmounts::currencyId))
                .map(amounts -> new PartyOpenBalanceView.CurrencyBalance(
                        amounts.currencyId(), name(amounts.currencyId()), isBase(amounts.currencyId()),
                        amounts.openOriginal(), amounts.creditOriginal(),
                        amounts.openOriginal().subtract(amounts.creditOriginal())))
                .toList();
        BigDecimal overLimit = creditLimitLocal == null
                ? null : party.openBookLocal().subtract(creditLimitLocal);
        return new PartyOpenBalanceView(
                currencyId, name(currencyId), isBase(currencyId),
                open, credit, open.subtract(credit), creditLocal,
                others,
                baseCurrencyName(),
                party.openBookLocal(), party.unverifiedLocal(), party.unverifiedCount(),
                creditLimitLocal, overLimit, overLimit != null && overLimit.signum() > 0);
    }

    private String name(UUID currencyId) {
        Currency currency = currencyId == null ? null : currencies.get(currencyId);
        return currency == null ? null : currency.name();
    }

    private boolean isBase(UUID currencyId) {
        Currency currency = currencyId == null ? null : currencies.get(currencyId);
        return currency != null && currency.base();
    }

    private String baseCurrencyName() {
        return currencies.values().stream().filter(Currency::base).map(Currency::name)
                .filter(Objects::nonNull).findFirst().orElse(null);
    }

    private static BigDecimal nz(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }
}
