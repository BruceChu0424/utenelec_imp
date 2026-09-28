package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasRow;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientGoodsHistory;
import com.uten.imp.application.port.MasterIntakeLookupPort.GoodsRow;
import com.uten.imp.features.sales.intake.GoodsMatcher.ClientContext;
import com.uten.imp.features.sales.intake.GoodsMatcher.Decision;
import com.uten.imp.features.sales.intake.GoodsMatcher.Evidence;
import com.uten.imp.features.sales.intake.GoodsMatcher.LineInput;
import com.uten.imp.features.sales.intake.GoodsMatcher.PriceContext;
import com.uten.imp.features.sales.intake.GoodsMatcher.Reason;
import com.uten.imp.features.sales.intake.GoodsMatcher.Scoring;
import com.uten.imp.features.sales.intake.GoodsMatcher.Status;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** 打分规则的定点测试(不依赖夹具): 每条规则一个最小例子。 */
class GoodsMatcherTest {

    private static final UUID CLIENT = UUID.fromString("00000000-0000-0000-0000-0000000000a1");

    static GoodsRow goods(String code, String name, String model, String series, String color, String spec, String price) {
        return new GoodsRow(UUID.nameUUIDFromBytes(code.getBytes()), code, name, model, series, spec, null, color, null, "个",
                null, null, price == null ? null : new BigDecimal(price), "使用");
    }

    static GoodsRow withNameEn(GoodsRow g, String nameEn, String source) {
        return new GoodsRow(g.id(), g.code(), g.name(), g.model(), g.series(), g.spec(), g.colorId(), g.colorName(), g.unitId(),
                g.unitName(), nameEn, source, g.price(), g.status());
    }

    static ExtractedLine line(String part, String series, String color, String colorAlt, String desc, String descAlt, String price) {
        return IntakeLineExtractor.build(new IntakeLineExtractor.RawLine("S1R9", "S", 9, "1", part, desc, descAlt, series,
                color, colorAlt, BigDecimal.TEN, null, null, price == null ? null : new BigDecimal(price), null,
                color != null || colorAlt != null));
    }

    private static Decision decide(ExtractedLine l, List<GoodsRow> pool, ClientContext client, List<AliasRow> aliases) {
        LineInput in = LineInput.of(l);
        Scoring s = GoodsMatcher.score(in, pool, client, aliases, PriceContext.BASE);
        return GoodsMatcher.decide(in, s, client);
    }

    private final GoodsRow z9White = goods("Z9-W", "Z9 146型二开多功能三孔\uFF08带灯\uFF09", "GZ23/D", "Z9", "白色", null, "21");
    private final GoodsRow z9Black = goods("Z9-B", "Z9 146型二开多功能三孔\uFF08带灯\uFF09", "GZ23/D", "Z9", "黑色", null, "21");
    private final GoodsRow m1White = goods("1M-W", "1M二开多功能三孔插座(不带灯\uFF09", "GZ23/D", "1M", "白色", null, "18");

    @Test
    void modelSeriesAndColourMakeAConfidentMatch() {
        Decision d = decide(line("GZ23/D", "Z9", "WHITE", "白色", "DOUBLE 3 PIN SOCKET", "两开多功能三极插座", "21"),
                List.of(z9White, z9Black, m1White), ClientContext.NONE, List.of());
        assertThat(d.status()).isEqualTo(Status.MATCHED);
        assertThat(d.top().goods).isEqualTo(z9White);
        assertThat(d.top().evidence).contains(Evidence.MODEL, Evidence.SERIES_MATCH, Evidence.COLOR_MATCH, Evidence.PRICE_MATCH);
        assertThat(d.top().raw).isEqualTo(80 + 10 + 8 + 4);
        assertThat(d.top().reportedScore()).isEqualTo(95);
    }

    @Test
    void withoutSeriesTheSameModelInSeveralSeriesNeedsHistory() {
        ExtractedLine noSeries = line("GZ23/D", null, "WHITE", "白色", null, null, null);
        Decision d = decide(noSeries, List.of(z9White, z9Black, m1White), ClientContext.NONE, List.of());
        assertThat(d.status()).isEqualTo(Status.REVIEW);
        assertThat(d.reason()).isIn(Reason.MULTI_SERIES, Reason.CLOSE_CANDIDATES, Reason.LOW_SCORE);
        ClientContext bought = new ClientContext(CLIENT, "尼日利亚A", "尼日利亚",
                Map.of(z9White.id(), new ClientGoodsHistory(z9White.id(), 5, LocalDate.of(2026, 5, 1))), LocalDate.of(2024, 8, 1));
        Decision withHistory = decide(noSeries, List.of(z9White, z9Black, m1White), bought, List.of());
        assertThat(withHistory.top().goods).isEqualTo(z9White);
        assertThat(withHistory.status()).isEqualTo(Status.MATCHED);
    }

    @Test
    void seriesAndColourConflictsNeverAutoMatch() {
        Decision wrongSeries = decide(line("GZ23/D", "6M", "WHITE", "白色", null, null, null), List.of(z9White, m1White),
                ClientContext.NONE, List.of());
        assertThat(wrongSeries.status()).isEqualTo(Status.REVIEW);
        assertThat(wrongSeries.reason()).isEqualTo(Reason.SERIES_CONFLICT);
        Decision wrongColour = decide(line("GZ23/D", "Z9", "GOLD", "金色", null, null, null), List.of(z9White, z9Black),
                ClientContext.NONE, List.of());
        assertThat(wrongColour.status()).isEqualTo(Status.REVIEW);
        assertThat(wrongColour.reason()).isEqualTo(Reason.COLOR_CONFLICT);
    }

    @Test
    void confirmedAliasIsAuthoritativeAndBeatsTheModelTier() {
        GoodsRow typeA = goods("USB-A", "Z9一开13A带USB", "GK11Z13A USB", "Z9", "白色", null, "36.8");
        GoodsRow typeAC = goods("USB-AC", "Z9一开13A带A+C双USB", null, "Z9", "白色", null, "36.8");
        ExtractedLine l = line("GK11Z13A USB", "Z9", "WHITE", "白色", "13A SINGLE SOCKET WITH SWITCH+ A+C DOUBLE USB",
                "一开13A带A+C 双USB", "36.8");
        Decision before = decide(l, List.of(typeA, typeAC), ClientContext.NONE, List.of());
        assertThat(before.status()).isEqualTo(Status.REVIEW);
        AliasRow learned = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "GK11Z13A USB",
                "GK11Z13AUSB", "Z9|白", typeAC.id(), 1, 1, OffsetDateTime.now());
        ClientContext client = new ClientContext(CLIENT, "客户", "", Map.of(), null);
        Decision after = decide(l, List.of(typeA, typeAC), client, List.of(learned));
        assertThat(after.status()).isEqualTo(Status.MATCHED);
        assertThat(after.top().goods).isEqualTo(typeAC);
        assertThat(after.top().raw).isEqualTo(99);
        assertThat(GoodsMatcher.find(GoodsMatcher.score(LineInput.of(l), List.of(typeA, typeAC), client, List.of(learned),
                PriceContext.BASE).ranked(), typeA.id()).raw).isLessThanOrEqualTo(89);
    }

    @Test
    void aliasConfirmedOnlyOnceIsNotYetAuthoritative() {
        AliasRow once = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "GZ23/D", "GZ23/D",
                "Z9|白", z9Black.id(), 1, 0, OffsetDateTime.now());
        Decision d = decide(line("GZ23/D", "Z9", "WHITE", "白色", null, null, null), List.of(z9White, z9Black),
                new ClientContext(CLIENT, "", "", Map.of(), null), List.of(once));
        assertThat(d.top().evidence).doesNotContain(Evidence.ALIAS_AUTHORITATIVE);
    }

    @Test
    void sameAliasPointingToTwoGoodsIsAmbiguous() {
        AliasRow a = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "X1", "X1", "", z9White.id(),
                3, 1, OffsetDateTime.now());
        AliasRow b = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "X1", "X1", "", z9Black.id(),
                3, 1, OffsetDateTime.now());
        Decision d = decide(line("X1", null, null, null, null, null, null), List.of(z9White, z9Black),
                new ClientContext(CLIENT, "", "", Map.of(), null), List.of(a, b));
        assertThat(d.status()).isEqualTo(Status.REVIEW);
        assertThat(d.reason()).isEqualTo(Reason.ALIAS_AMBIGUOUS);
    }

    @Test
    void userCorrectionBeatsAnAutoLearnedAliasForTheSameWording() {
        // 第一张单系统自动对到黑色并被保存学到(确认 1 次, 没人明确选过);
        // 第二张单用户把它改成白色(明确选择)。第三次识别应直接对到白色, 不再判成有歧义。
        AliasRow autoLearned = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "GZ23/D",
                "GZ23/D", "Z9|白", z9Black.id(), 1, 0, OffsetDateTime.now().minusDays(2));
        AliasRow corrected = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "GZ23/D",
                "GZ23/D", "Z9|白", z9White.id(), 1, 1, OffsetDateTime.now());
        ClientContext client = new ClientContext(CLIENT, "", "", Map.of(), null);
        Decision d = decide(line("GZ23/D", "Z9", "WHITE", "白色", null, null, null), List.of(z9White, z9Black),
                client, List.of(autoLearned, corrected));
        assertThat(d.status()).isEqualTo(Status.MATCHED);
        assertThat(d.top().goods).isEqualTo(z9White);
        assertThat(d.top().evidence).contains(Evidence.ALIAS_AUTHORITATIVE);
    }

    @Test
    void englishNameDropsTheTrailingSpecLine() {
        assertThat(SalesIntakePipeline.nameEnText(line("GK42", "Z9", "WHITE", null,
                "4 GANG 2 WAY SWITCH WITH LED Current: 10A", null, "22"))).isEqualTo("4 GANG 2 WAY SWITCH WITH LED");
        assertThat(SalesIntakePipeline.nameEnText(line("GK45A", "Z9", "WHITE", null,
                "45A switch 3*3 Current: 45A", null, "17.85"))).isEqualTo("45A switch 3*3");
        assertThat(SalesIntakePipeline.nameEnText(line("GZ23/D", "Z9", "WHITE", null,
                "DOUBLE 3 PIN UNIVERSAL SOCCKET WITH SWITCH", null, "21")))
                .isEqualTo("DOUBLE 3 PIN UNIVERSAL SOCCKET WITH SWITCH");
    }

    @Test
    void twoExplicitChoicesForTheSameWordingStayAmbiguous() {
        AliasRow a = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "X1", "X1", "", z9White.id(),
                1, 1, OffsetDateTime.now());
        AliasRow b = new AliasRow(UUID.randomUUID(), AliasScope.CLIENT, CLIENT, AliasKind.PART_NO, "X1", "X1", "", z9Black.id(),
                1, 1, OffsetDateTime.now());
        Decision d = decide(line("X1", null, null, null, null, null, null), List.of(z9White, z9Black),
                new ClientContext(CLIENT, "", "", Map.of(), null), List.of(a, b));
        assertThat(d.status()).isEqualTo(Status.REVIEW);
        assertThat(d.reason()).isEqualTo(Reason.ALIAS_AMBIGUOUS);
    }

    @Test
    void shortChineseDescriptionIsOnlyCorroboration() {
        GoodsRow blankZ9 = goods("Z9-M", "Z9空白面盖", "M/D", "Z9", "白色", null, "6.5");
        GoodsRow blank6M = goods("6M-M", "尼日利亚6M  空白面板", "G-M/D", "6M", "响臻白", null, "6.5");
        ExtractedLine l = line("G-M/D", "Z9", "WHITE", "白色", "BLANK COVER", "空白面板", "6.5");
        Scoring s = GoodsMatcher.score(LineInput.of(l), List.of(blankZ9, blank6M), ClientContext.NONE, List.of(), PriceContext.BASE);
        GoodsMatcher.Scored other = GoodsMatcher.find(s.ranked(), blank6M.id());
        assertThat(other.evidence).doesNotContain(Evidence.NAME_EXACT).contains(Evidence.NAME_SHORT_AGREES,
                Evidence.SERIES_CONFLICT, Evidence.OTHER_CUSTOMER);
        Decision d = GoodsMatcher.decide(LineInput.of(l), s, ClientContext.NONE);
        assertThat(d.top().goods).isEqualTo(blankZ9);
        assertThat(d.top().evidence).contains(Evidence.MODEL_VARIANT);
        assertThat(d.status()).isEqualTo(Status.MATCHED);
    }

    @Test
    void nameFamilySiblingsBlockANameOnlyMatch() {
        GoodsRow plain = goods("V71025", "V7小二孔安全门弹簧", null, "V7", null, null, null);
        GoodsRow steel = goods("V71028", "V7小二孔安全门弹簧\uFF08不锈钢\uFF09", null, "V7", null, null, null);
        Decision d = decide(line("Z10E-07", null, null, null, "Spring", "V7小二孔安全门弹簧", null), List.of(plain, steel),
                ClientContext.NONE, List.of());
        assertThat(d.top().goods).isEqualTo(plain);
        assertThat(d.status()).isEqualTo(Status.REVIEW);
        assertThat(d.reason()).isEqualTo(Reason.SAME_NAME_SIBLINGS);
    }

    @Test
    void uniqueChineseNameWithoutModelCanAutoMatch() {
        GoodsRow shutter = goods("V50052", "V5多功能保护门", null, "V5", "黑色", null, "0");
        GoodsRow other = goods("V50084", "V5多功能五孔后座", null, "V5", "深灰色", null, "0");
        Decision alone = decide(line("Z13N-03", null, null, null, "Shutter", "V5多功能保护门", null), List.of(shutter, other),
                ClientContext.NONE, List.of());
        assertThat(alone.status()).as("85 alone is below the auto-match bar").isEqualTo(Status.REVIEW);
        ClientContext bought = new ClientContext(CLIENT, "Bravo", "约旦",
                Map.of(shutter.id(), new ClientGoodsHistory(shutter.id(), 4, LocalDate.of(2026, 5, 1))), LocalDate.of(2024, 8, 1));
        Decision d = decide(line("Z13N-03", null, null, null, "Shutter", "V5多功能保护门", null), List.of(shutter, other),
                bought, List.of());
        assertThat(d.status()).isEqualTo(Status.MATCHED);
        assertThat(d.top().goods).isEqualTo(shutter);
    }

    @Test
    void oneEditModelWithinTheSeriesIsReviewOnly() {
        GoodsRow near = goods("6M-5", "尼日利亚6M 小按钮一开多功能五孔插座\uFF08带灯\uFF09", "GK11Z12Z13A/D", "6M", "黑色\uFF086143\uFF09", null, "9.5");
        ExtractedLine l = line("GK11Z12Z13/D", "6M", "BLACK", "黑色", null, null, "9.5");
        Decision d = decide(l, List.of(near), new ClientContext(CLIENT, "尼日利亚A", "尼日利亚", Map.of(), null), List.of());
        assertThat(d.top().evidence).contains(Evidence.MODEL_ONE_EDIT, Evidence.OWN_PREFIX);
        assertThat(d.status()).isEqualTo(Status.REVIEW);
        assertThat(GoodsMatcher.oneEdit("GK11Z12Z13A/D", "GK11Z12Z13/D")).isTrue();
        assertThat(GoodsMatcher.oneEdit("ABC", "ABC")).isFalse();
        assertThat(GoodsMatcher.oneEdit("ABCD", "AB")).isFalse();
    }

    @Test
    void bundlesAreAlwaysReviewAndFrameColourCounts() {
        GoodsRow tel = goods("Q120G017", "Q120电话插模块功能件", "TEL-01", "Q120", "杏色", null, "0");
        ExtractedLine bundle = IntakeLineExtractor.build(new IntakeLineExtractor.RawLine("S1R29", "S", 29, "19",
                "TEL-02+TEL-02-W+PC-03", "Telephone modular+shutter", "电话插模块功能件+电话保护门 (杏色\uFF09+保护门弹簧\uFF08组装成功能件\uFF09",
                null, null, null, BigDecimal.TEN, null, null, null, null, false));
        Decision d = decide(bundle, List.of(tel), ClientContext.NONE, List.of());
        assertThat(d.status()).isEqualTo(Status.REVIEW);
        assertThat(d.reason()).isEqualTo(Reason.BUNDLE);
        assertThat(d.top().goods).isEqualTo(tel);

        GoodsRow plainFrame = goods("B1", "Z9 20A开关", "GK20A", "Z9", "黑色", null, "15.96");
        GoodsRow goldFrame = goods("B2", "Z9 20A开关", "GK20A", "Z9", "黑色", "金色面框", "15.96");
        Scoring s = GoodsMatcher.score(LineInput.of(line("GK20A", "Z9", "BLACK+GRAY BORDER", "黑色", null, null, null)),
                List.of(goldFrame, plainFrame), ClientContext.NONE, List.of(), PriceContext.BASE);
        assertThat(s.ranked().getFirst().goods).isEqualTo(plainFrame);
        assertThat(GoodsMatcher.find(s.ranked(), goldFrame.id()).evidence).contains(Evidence.FRAME_CONFLICT);
    }

    @Test
    void customerPriceFarBelowListPriceFlagsOddDiscount() {
        GoodsRow expensive = goods("E1", "Z9 20A开关", "GK20A", "Z9", "白色", null, "100");
        Decision d = decide(line("GK20A", "Z9", "WHITE", "白色", null, null, "10"), List.of(expensive), ClientContext.NONE, List.of());
        assertThat(d.top().evidence).contains(Evidence.DISCOUNT_ODD);
        assertThat(d.status()).isEqualTo(Status.REVIEW);
        assertThat(d.reason()).isEqualTo(Reason.DISCOUNT_ODD);
        Scoring usd = GoodsMatcher.score(LineInput.of(line("GK20A", "Z9", "WHITE", "白色", null, null, "13")), List.of(expensive),
                ClientContext.NONE, List.of(), new PriceContext(true, 7.1));
        assertThat(usd.ranked().getFirst().evidence).doesNotContain(Evidence.DISCOUNT_ODD);
    }

    @Test
    void englishNameLearnedOrManualIsExactEvidence() {
        GoodsRow g = withNameEn(goods("EN1", "Z9一开双控\uFF08带灯\uFF09", null, "Z9", "白色", null, "9.45"), "1 GANG 2 WAY SWITCH WITH LED",
                "MANUAL");
        GoodsRow other = goods("EN2", "Z9二开双控\uFF08带灯\uFF09", null, "Z9", "白色", null, "14.18");
        Decision d = decide(line("X-1", null, null, null, "1 Gang 2 Way Switch with LED", null, "9.45"), List.of(g, other),
                ClientContext.NONE, List.of());
        assertThat(d.top().goods).isEqualTo(g);
        assertThat(d.top().evidence).contains(Evidence.NAME_EN_EXACT);
        assertThat(d.top().raw).isEqualTo(88 + 4);
        assertThat(d.status()).isEqualTo(Status.MATCHED);
        assertThat(GoodsMatcher.trigramSimilarity("word", "word")).isEqualTo(1.0);
    }

    @Test
    void historyAndOwnerPrefixAdjustments() {
        GoodsRow own = goods("N1", "尼日利亚6M  单联双控", "GK12", "6M", "黑色\uFF086143\uFF09", null, "6");
        GoodsRow others = goods("I1", "伊拉克二6M单联双控", "GK12", "6M", "黑色\uFF086143\uFF09", null, "6");
        ClientContext client = new ClientContext(CLIENT, "尼日利亚ALPHA", "尼日利亚",
                Map.of(own.id(), new ClientGoodsHistory(own.id(), 3, LocalDate.of(2026, 1, 1))), LocalDate.of(2024, 8, 1));
        Scoring s = GoodsMatcher.score(LineInput.of(line("GK12", "6M", "BLACK", "黑色", null, null, "6")), List.of(own, others),
                client, List.of(), PriceContext.BASE);
        GoodsMatcher.Scored top = s.ranked().getFirst();
        assertThat(top.goods).isEqualTo(own);
        assertThat(top.raw).isEqualTo(80 + 10 + 8 + 9 + 4 + 4);
        assertThat(GoodsMatcher.find(s.ranked(), others.id()).raw).isEqualTo(80 + 10 + 8 - 10 + 4);
        assertThat(IntakeTexts.reasons(top)).contains("型号一致", "该客户买过(3次)", "该客户专用货品");
    }
}
