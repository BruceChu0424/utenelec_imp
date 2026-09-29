package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 单据旁边显示的往来余额(ADR-128)：按单据币种精确求和, 其它币种各自列出, 信用对比用全币种账面本币。
 *
 * <p>由 {@link PartyOpenBalances#forDocument} 一次派生, 服务端只算这一次, 前端只显示:
 * <ul>
 *   <li>单据币种一档({@code currencyId}): {@code openOriginal} = 应收(应付)未结原币, 含退货红字;
 *       {@code creditOriginal} = 可用预收 / 预付 / 贷项 / 索赔贷项原币(正数);
 *       {@code netOriginal} = open − credit, 正数 = 对方还欠(我方还欠)这么多, 负数 = 预收(预付)有余。</li>
 *   <li>{@code otherCurrencies}: 同一往来单位其它币种的余额, 各用自己的币种, 不换算、不相加
 *       (主档参考汇率未维护, 今天的汇率也不是账面事实)。</li>
 *   <li>{@code openBookLocal}: 全部币种正式应收(应付)行的账面本币毛额, 不扣预收;
 *       信用额度 / 铺底额只和它比(全平台一个口径)。</li>
 *   <li>{@code unverifiedLocal}: 旧系统迁入、或缺币种 / 缺原币的外币余额, 只有本币可信, 单列不并入任何币种。</li>
 *   <li>{@code creditLimitLocal} 为空 = 未设置额度, {@code overCredit} 恒 false;
 *       否则 {@code overLimitLocal} = openBookLocal − 额度(可为负), {@code overCredit} = 它大于 0。</li>
 * </ul>
 * 金额按十进制原文输出为 JSON 字符串(ADR-112 ExactDecimalText)。
 */
public record PartyOpenBalanceView(
        UUID currencyId,
        String currencyName,
        boolean baseCurrency,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal openOriginal,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal creditOriginal,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal netOriginal,
        /** 单据币种可用预收(预付/贷项)的账面本币(正数)；出货放行事件冻结它。 */
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal creditBookLocal,
        List<CurrencyBalance> otherCurrencies,
        String baseCurrencyName,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal openBookLocal,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal unverifiedLocal,
        long unverifiedCount,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal creditLimitLocal,
        @JsonSerialize(using = ExactDecimalText.class) BigDecimal overLimitLocal,
        boolean overCredit) {

    public PartyOpenBalanceView {
        otherCurrencies = List.copyOf(otherCurrencies);
    }

    /** 其它币种一档：各用自己的币种原币, 不换算。 */
    public record CurrencyBalance(
            UUID currencyId,
            String currencyName,
            boolean baseCurrency,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal openOriginal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal creditOriginal,
            @JsonSerialize(using = ExactDecimalText.class) BigDecimal netOriginal) {
    }
}
