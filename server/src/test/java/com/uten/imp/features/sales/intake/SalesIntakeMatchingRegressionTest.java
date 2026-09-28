package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 货品匹配回归闸门(SPEC §5.5): 用我司货品资料快照 + 按两份真实客户文件形状合成的表格, 走完整识别流水线(读表 → 版式 →
 * 抽取 → 不看客户匹配 → 找客户 → 按客户重打分 → 定价), 对照旧系统里真实订单的答案:
 * 自动对应(MATCHED)的准确率必须 100%, 正确货品出现在前 8 个候选里的比例 ≥ 93%;
 * 去掉「系列」列后(很多客户文件没有系列)也不能出现任何错误的自动对应。
 */
class SalesIntakeMatchingRegressionTest {

    private static final ObjectMapper JSON = new ObjectMapper();

    /**
     * @param priceBlockedCorrect 货品已确切对上、只因标价为0/客户价高于标价被转为待核对(定价阻断)且对应正确的行
     * @param clientHeldCorrect   只因客户还没确认(按推测客户的历史才够得上)被转为待核对、且预选正确的行
     */
    record Stats(int lines, int matched, int matchedCorrect, int review, int unmatched, int inTop8, int topCorrect,
                 int priceBlockedCorrect, int priceBlockedWrong, int clientHeldCorrect, int clientHeldWrong,
                 int matchedWithoutDiscount, List<String> report) {

        /** 货品判定层面的自动对应(含因定价、客户未确认转待核对的)是否全部正确。 */
        boolean goodsLevelPrecise() {
            return matchedCorrect == matched && priceBlockedWrong == 0 && clientHeldWrong == 0;
        }
    }

    static Map<String, Object> runPipeline(FixtureLookup lookup, byte[] xlsx, String fileName, String clientParam) {
        FakeJobContext ctx = FakeJobContext.of(fileName, "XLSX", xlsx, "quote");
        if (clientParam != null) {
            ctx.params.put("clientId", clientParam);
        }
        SalesIntakePipeline pipeline = new SalesIntakePipeline(lookup, new FakeReferenceData(), JSON, () -> false,
                Clock.fixed(lookup.fixture.asOf.atStartOfDay(ZoneId.of("Asia/Shanghai")).toInstant(),
                        ZoneId.of("Asia/Shanghai")));
        return pipeline.run(ctx);
    }

    @SuppressWarnings("unchecked")
    static Stats evaluate(IntakeFixture fixture, IntakeFixture.FixtureDocument doc, Map<String, Object> result) {
        List<Map<String, Object>> lines = (List<Map<String, Object>>) result.get("lines");
        int matched = 0;
        int matchedCorrect = 0;
        int review = 0;
        int unmatched = 0;
        int inTop8 = 0;
        int topCorrect = 0;
        int priceBlockedCorrect = 0;
        int priceBlockedWrong = 0;
        int clientHeldCorrect = 0;
        int clientHeldWrong = 0;
        int matchedWithoutDiscount = 0;
        String clientHeldReason = IntakeTexts.reasonText(GoodsMatcher.Reason.CLIENT_UNCONFIRMED, 0);
        List<String> report = new ArrayList<>();
        for (IntakeFixture.TruthLine truth : doc.lines()) {
            Map<String, Object> line = lines.stream().filter(l -> ((Number) l.get("sourceRow")).intValue() == truth.row())
                    .findFirst().orElse(null);
            assertThat(line).as("row %s extracted", truth.row()).isNotNull();
            String status = (String) line.get("status");
            String selected = (String) line.get("selectedGoodsId");
            List<Map<String, Object>> candidates = (List<Map<String, Object>>) line.get("candidates");
            boolean selectedOk = selected != null && truth.truth().contains(UUID.fromString(selected));
            boolean top8 = candidates.stream().anyMatch(c -> truth.truth().contains(UUID.fromString((String) c.get("goodsId"))));
            boolean topOk = !candidates.isEmpty()
                    && truth.truth().contains(UUID.fromString((String) candidates.getFirst().get("goodsId")));
            switch (status) {
                case "MATCHED" -> {
                    matched++;
                    if (selectedOk) {
                        matchedCorrect++;
                    }
                    Map<String, Object> chosen = candidates.stream().filter(c -> c.get("goodsId").equals(selected))
                            .findFirst().orElse(null);
                    if (line.get("customerUnitPrice") != null && (chosen == null || chosen.get("discount") == null)) {
                        matchedWithoutDiscount++;
                    }
                }
                case "REVIEW" -> review++;
                default -> unmatched++;
            }
            if (top8) {
                inTop8++;
            }
            if (topOk) {
                topCorrect++;
            }
            List<Map<String, Object>> warnings = (List<Map<String, Object>>) line.get("warnings");
            boolean priceBlocked = warnings.stream().anyMatch(w -> "NO_LIST_PRICE".equals(w.get("code"))
                    || "ABOVE_LIST".equals(w.get("code")));
            boolean goodsDecided = "REVIEW".equals(status) && priceBlocked && line.get("reasonText") != null
                    && ((String) line.get("reasonText")).startsWith(priceBlockedReasonPrefix(warnings));
            if (goodsDecided && selectedOk) {
                priceBlockedCorrect++;
            } else if (goodsDecided) {
                priceBlockedWrong++;
            }
            if ("REVIEW".equals(status) && clientHeldReason.equals(line.get("reasonText"))) {
                if (selectedOk) {
                    clientHeldCorrect++;
                } else {
                    clientHeldWrong++;
                }
            }
            String truthCodes = String.join(",", truth.truth().stream().map(id -> fixture.goodsById.get(id).code()).toList());
            String top = candidates.isEmpty() ? "-" : candidates.getFirst().get("code") + "(" + candidates.getFirst().get("score") + ")";
            report.add(String.format("R%-3d %-18s %-8s %-4s top=%-18s truth=%-22s inTop8=%s %s", truth.row(),
                    String.valueOf(line.get("partNo")), status, selectedOk ? "OK" : (selected == null ? "-" : "BAD"), top,
                    truthCodes, top8, line.get("reasonText") == null ? "" : line.get("reasonText")));
        }
        // 金额规则(每次评估都查): 文件有单价的已对应行一定带折扣, 算不出折扣的行必须转待核对。
        assertThat(matchedWithoutDiscount).as(doc.key() + ": MATCHED lines with a customer price but no discount").isZero();
        return new Stats(doc.lines().size(), matched, matchedCorrect, review, unmatched, inTop8, topCorrect,
                priceBlockedCorrect, priceBlockedWrong, clientHeldCorrect, clientHeldWrong, matchedWithoutDiscount, report);
    }

    /** 定价阻断时 reasonText 就是定价提示(说明货品判定本身是自动对应)。 */
    private static String priceBlockedReasonPrefix(List<Map<String, Object>> warnings) {
        return warnings.stream().filter(w -> "NO_LIST_PRICE".equals(w.get("code")) || "ABOVE_LIST".equals(w.get("code")))
                .map(w -> (String) w.get("message")).findFirst().orElse("\u0000");
    }

    private static void print(String label, Stats s, Map<String, Object> result) {
        System.out.println("=== " + label + ": lines=" + s.lines() + " matched=" + s.matched() + " (correct "
                + s.matchedCorrect() + ") review=" + s.review() + " unmatched=" + s.unmatched() + " inTop8=" + s.inTop8()
                + " topCorrect=" + s.topCorrect() + " matchedButPriceBlocked=" + s.priceBlockedCorrect()
                + " heldForUnconfirmedClient=" + s.clientHeldCorrect()
                + " client=" + ((Map<?, ?>) result.get("client")).get("status"));
        s.report().forEach(System.out::println);
    }

    @Test
    void sunasShapedFileMatchesWithoutAnyWrongAutoMatch() {
        IntakeFixture fixture = IntakeFixture.load();
        IntakeFixture.FixtureDocument doc = fixture.document("SUNAS");
        Map<String, Object> result = runPipeline(new FixtureLookup(fixture), IntakeFixture.toXlsx(doc), "SUNAS.xlsx", null);
        Stats s = evaluate(fixture, doc, result);
        print("SUNAS", s, result);
        assertThat(s.matchedCorrect()).as("MATCHED precision").isEqualTo(s.matched());
        assertThat(s.goodsLevelPrecise()).as("goods-level auto matches (incl. price-blocked) all correct").isTrue();
        assertThat(s.matched() + s.priceBlockedCorrect()).as("most lines auto-matched").isGreaterThanOrEqualTo(30);
        assertThat((double) s.inTop8() / s.lines()).as("correct goods in top 8").isGreaterThanOrEqualTo(0.93);
        Map<?, ?> client = (Map<?, ?>) result.get("client");
        assertThat(client.get("status")).isEqualTo("MATCHED");
        assertThat(client.get("selectedClientId")).isEqualTo(fixture.client("CLIENT_A").id().toString());
    }

    @Test
    void uj23ShapedFileMatchesWithoutAnyWrongAutoMatch() {
        IntakeFixture fixture = IntakeFixture.load();
        IntakeFixture.FixtureDocument doc = fixture.document("UJ23");
        FixtureLookup lookup = new FixtureLookup(fixture);
        Map<String, Object> result = runPipeline(lookup, IntakeFixture.toXlsx(doc), "UJ23 quotation.xlsx", null);
        Stats s = evaluate(fixture, doc, result);
        print("UJ23", s, result);
        assertThat(lookup.calls.stream().filter(c -> c.startsWith("historyContains:")).toList())
                .as("basket only among clue candidates, never an empty client set")
                .isNotEmpty().doesNotContain("historyContains:0");
        assertThat(s.matchedCorrect()).as("MATCHED precision").isEqualTo(s.matched());
        assertThat(s.goodsLevelPrecise()).isTrue();
        // 客户只是按篮子推测(待核对): 靠它的历史才够得上的行只预选、不自动对应, 但预选必须正确。
        assertThat(s.matched() + s.priceBlockedCorrect() + s.clientHeldCorrect())
                .as("unique Chinese names still found and preselected").isGreaterThanOrEqualTo(7);
        assertThat(s.clientHeldCorrect()).as("history of an unconfirmed client never auto-matches").isPositive();
        Map<?, ?> client = (Map<?, ?>) result.get("client");
        assertThat(client.get("status")).as("basket-only evidence never auto-selects").isEqualTo("REVIEW");
        assertThat(client.get("selectedClientId")).isEqualTo(fixture.client("CLIENT_B").id().toString());
    }

    @Test
    void bothFilesTogetherMeetTheAccuracyGate() {
        IntakeFixture fixture = IntakeFixture.load();
        int lines = 0;
        int matched = 0;
        int matchedCorrect = 0;
        int inTop8 = 0;
        for (String key : List.of("SUNAS", "UJ23")) {
            IntakeFixture.FixtureDocument doc = fixture.document(key);
            Map<String, Object> result = runPipeline(new FixtureLookup(fixture), IntakeFixture.toXlsx(doc), key + ".xlsx", null);
            Stats s = evaluate(fixture, doc, result);
            lines += s.lines();
            matched += s.matched();
            matchedCorrect += s.matchedCorrect();
            inTop8 += s.inTop8();
            assertThat(s.goodsLevelPrecise()).as(key).isTrue();
        }
        System.out.println("=== GATE lines=" + lines + " matched=" + matched + " correct=" + matchedCorrect + " inTop8=" + inTop8
                + " (" + String.format("%.1f%%", 100.0 * inTop8 / lines) + ")");
        assertThat(lines).isEqualTo(60);
        assertThat(matchedCorrect).as("MATCHED precision 100%%").isEqualTo(matched);
        assertThat((double) inTop8 / lines).as("correct goods in top 8 >= 93%%").isGreaterThanOrEqualTo(0.93);
    }

    @Test
    void sunasWithoutSeriesColumnNeverAutoMatchesWrongly() {
        IntakeFixture fixture = IntakeFixture.load();
        IntakeFixture.FixtureDocument doc = fixture.document("SUNAS");
        Predicate<String> noSeries = col -> !"B".equals(col);
        Map<String, Object> result = runPipeline(new FixtureLookup(fixture), IntakeFixture.toXlsx(doc, noSeries),
                "SUNAS-no-series.xlsx", null);
        Stats s = evaluate(fixture, doc, result);
        print("SUNAS without series", s, result);
        assertThat(s.matchedCorrect()).as("no wrong MATCHED without series").isEqualTo(s.matched());
        assertThat(s.goodsLevelPrecise()).isTrue();
    }

    @Test
    void preselectedClientGivesTheSameSafeResult() {
        IntakeFixture fixture = IntakeFixture.load();
        for (String key : List.of("SUNAS", "UJ23")) {
            IntakeFixture.FixtureDocument doc = fixture.document(key);
            String clientId = fixture.client(doc.clientKey()).id().toString();
            Map<String, Object> result = runPipeline(new FixtureLookup(fixture), IntakeFixture.toXlsx(doc), key + ".xlsx",
                    clientId);
            Stats s = evaluate(fixture, doc, result);
            print(key + " preselected", s, result);
            assertThat(s.matchedCorrect()).isEqualTo(s.matched());
            assertThat(s.goodsLevelPrecise()).isTrue();
            assertThat(s.clientHeldCorrect() + s.clientHeldWrong()).as("a chosen client is confirmed").isZero();
            if (key.equals("UJ23")) {
                assertThat(s.matched() + s.priceBlockedCorrect()).as("unique Chinese names auto-match for the chosen client")
                        .isGreaterThanOrEqualTo(7);
            }
            assertThat(((Map<?, ?>) result.get("client")).get("status")).isEqualTo("PRESET");
        }
    }

    @Test
    void goodsOnlyVisibleThroughTheLookupAreEverSuggested() {
        IntakeFixture fixture = IntakeFixture.load();
        IntakeFixture.FixtureDocument doc = fixture.document("SUNAS");
        Map<String, Object> result = runPipeline(new FixtureLookup(fixture), IntakeFixture.toXlsx(doc), "SUNAS.xlsx", null);
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> lines = (List<Map<String, Object>>) result.get("lines");
        Set<UUID> invisible = fixture.invisibleGoods;
        for (Map<String, Object> line : lines) {
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> candidates = (List<Map<String, Object>>) line.get("candidates");
            for (Map<String, Object> c : candidates) {
                assertThat(invisible).doesNotContain(UUID.fromString((String) c.get("goodsId")));
            }
        }
    }
}
