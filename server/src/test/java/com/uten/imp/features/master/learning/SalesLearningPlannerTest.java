package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** 学习规则(ADR-134 / SPEC §5.8)的纯函数测试: 学什么、学成哪种范围、什么时候不学。 */
class SalesLearningPlannerTest {

    private static final UUID CLIENT = UUID.fromString("00000000-0000-0000-0000-00000000c001");
    private static final UUID GOODS_A = UUID.fromString("00000000-0000-0000-0000-00000000000a");
    private static final UUID GOODS_B = UUID.fromString("00000000-0000-0000-0000-00000000000b");
    private static final UUID DOC = UUID.fromString("00000000-0000-0000-0000-0000000000d1");

    @Test
    void matchedLineLeftUnchangedLearnsClientAndGlobalAliasesWithTheJobContext() {
        IntakeJobLines job = job(line("S1R9", "GZ23/D", "DOUBLE 3 PIN UNIVERSAL SOCCKET WITH SWITCH", "两开多功能三极插座",
                "Z9|白", "MATCHED", GOODS_A, null));

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ23/D", "DOUBLE 3 PIN UNIVERSAL SOCCKET WITH SWITCH", "S1R9", false, false)),
                job);

        assertThat(plan.aliases()).extracting(SalesLearningPlanner.AliasUpsert::scope, SalesLearningPlanner.AliasUpsert::kind,
                        SalesLearningPlanner.AliasUpsert::norm, SalesLearningPlanner.AliasUpsert::context,
                        SalesLearningPlanner.AliasUpsert::explicit)
                .containsExactlyInAnyOrder(
                        org.assertj.core.groups.Tuple.tuple(AliasScope.CLIENT, AliasKind.PART_NO, "GZ23/D", "Z9|白", false),
                        org.assertj.core.groups.Tuple.tuple(AliasScope.GLOBAL, AliasKind.PART_NO, "GZ23/D", "Z9|白", false),
                        org.assertj.core.groups.Tuple.tuple(AliasScope.CLIENT, AliasKind.DESCRIPTION,
                                "double 3 pin universal soccket with switch", "Z9|白", false),
                        org.assertj.core.groups.Tuple.tuple(AliasScope.GLOBAL, AliasKind.DESCRIPTION,
                                "double 3 pin universal soccket with switch", "Z9|白", false));
        assertThat(plan.aliases()).allMatch(alias -> alias.goodsId().equals(GOODS_A));
        assertThat(plan.aliases()).filteredOn(alias -> alias.scope() == AliasScope.GLOBAL)
                .allMatch(alias -> alias.clientId() == null);
        assertThat(plan.nameEn()).as("没勾选「设为货品英文名」不学英文名").isEmpty();
    }

    @Test
    void reviewLineIsLearnedOnlyWhenTheUserExplicitlyConfirmedIt() {
        IntakeJobLines job = job(line("S1R10", "GK12", null, null, "Z9|白", "REVIEW", GOODS_B, null));

        assertThat(SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GK12", null, "S1R10", false, false)), job).aliases())
                .as("未确认的待核对行不学").isEmpty();
        assertThat(SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_B, "GK12", null, "S1R10", false, false)), job).aliases())
                .as("待核对行即使货品与识别首选相同, 没有明确确认也不学").isEmpty();

        SalesLearningPlanner.Plan confirmed = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GK12", null, "S1R10", true, false)), job);
        assertThat(confirmed.aliases()).hasSize(2).allMatch(SalesLearningPlanner.AliasUpsert::explicit)
                .allMatch(alias -> alias.goodsId().equals(GOODS_A));
    }

    @Test
    void matchedLineWhoseGoodsWasChangedWithoutConfirmationIsNotLearned() {
        IntakeJobLines job = job(line("S1R9", "GZ23/D", null, null, "Z9|白", "MATCHED", GOODS_A, null));

        assertThat(SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_B, "GZ23/D", null, "S1R9", false, false)), job).isEmpty()).isTrue();
    }

    @Test
    void freeTypedTextIsLearnedAsClientAliasOnlyNeverGlobalNorEnglishName() {
        IntakeJobLines job = job(line("S1R9", "GZ23/D", "DOUBLE SOCKET", null, "Z9|白", "MATCHED", GOODS_A,
                "DOUBLE SOCKET"));

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ-23D", "my own words here", "S1R9", true, true)), job);

        assertThat(plan.aliases()).isNotEmpty().allMatch(alias -> alias.scope() == AliasScope.CLIENT);
        assertThat(plan.nameEn()).as("手打的品名不写货品英文名").isEmpty();

        SalesLearningPlanner.Plan manualRow = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "K-100", "SOME DESCRIPTION", null, true, true)), IntakeJobLines.empty());
        assertThat(manualRow.aliases()).extracting(SalesLearningPlanner.AliasUpsert::scope, SalesLearningPlanner.AliasUpsert::context)
                .containsOnly(org.assertj.core.groups.Tuple.tuple(AliasScope.CLIENT, ""));
        assertThat(manualRow.nameEn()).isEmpty();
    }

    @Test
    void partNumberIsNormalizedLikeTheSeedAndMatchesJobTextAcrossWidthAndDashVariants() {
        IntakeJobLines job = job(line("S1R9", "gz23／d", null, null, "", "MATCHED", GOODS_A, null));

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, " GZ23 / D. ", null, "S1R9", false, false)), job);

        assertThat(plan.aliases()).extracting(SalesLearningPlanner.AliasUpsert::norm).containsOnly("GZ23/D");
        assertThat(plan.aliases()).extracting(SalesLearningPlanner.AliasUpsert::scope)
                .as("与识别原文规范化后一致, 算来自文件").contains(AliasScope.GLOBAL);
        assertThat(plan.aliases()).extracting(SalesLearningPlanner.AliasUpsert::text).containsOnly("GZ23 / D.");
    }

    @Test
    void aliasKeyMappedToSeveralGoodsInTheSameDocumentIsNotLearned() {
        IntakeJobLines job = job(
                line("S1R9", "WTV-03+WTV-04", null, null, "", "REVIEW", null, null),
                line("S1R10", "WTV-03+WTV-04", null, null, "", "REVIEW", null, null),
                line("S1R11", "GZ23/D", null, null, "Z9|白", "MATCHED", GOODS_A, null));

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "WTV-03+WTV-04", null, "S1R9", true, false),
                new LearnedLine(GOODS_B, "WTV-03+WTV-04", null, "S1R10", true, false),
                new LearnedLine(GOODS_A, "GZ23/D", null, "S1R11", false, false)), job);

        assertThat(plan.aliases()).extracting(SalesLearningPlanner.AliasUpsert::norm).containsOnly("GZ23/D");
    }

    @Test
    void sameKeyOnTwoLinesWithTheSameGoodsIsLearnedOnceAndExplicitWins() {
        IntakeJobLines job = job(
                line("S1R9", "GZ23/D", null, null, "Z9|白", "MATCHED", GOODS_A, null),
                line("S1R10", "GZ23/D", null, null, "Z9|白", "REVIEW", GOODS_B, null));

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ23/D", null, "S1R9", false, false),
                new LearnedLine(GOODS_A, "GZ23/D", null, "S1R10", true, false)), job);

        assertThat(plan.aliases()).hasSize(2)
                .allMatch(SalesLearningPlanner.AliasUpsert::explicit)
                .extracting(SalesLearningPlanner.AliasUpsert::scope)
                .containsExactlyInAnyOrder(AliasScope.CLIENT, AliasScope.GLOBAL);
    }

    @Test
    void englishNameIsLearnedOnlyFromTickedLinesWithDistinctiveJobText() {
        IntakeJobLines job = job(
                line("R1", "GZ23/D", "DOUBLE 3 PIN SOCKET WITH SWITCH", "两开插座", "Z9|白", "MATCHED", GOODS_A,
                        "DOUBLE 3 PIN SOCKET WITH SWITCH"),
                line("R2", "GK12", "SWITCH", null, "Z9|白", "MATCHED", GOODS_B, "SWITCH"));

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ23/D", "DOUBLE 3 PIN SOCKET WITH SWITCH", "R1", false, true),
                new LearnedLine(GOODS_B, "GK12", "SWITCH", "R2", false, true)), job);

        assertThat(plan.nameEn()).containsExactly(
                new SalesLearningPlanner.NameEnCandidate(GOODS_A, "DOUBLE 3 PIN SOCKET WITH SWITCH"));
    }

    @Test
    void englishTextUsedForSeveralGoodsInOneDocumentIsNotLearnedForAny() {
        IntakeJobLines job = job(
                line("R1", "GZ23/D", "DOUBLE 3 PIN SOCKET", null, "Z9|白", "MATCHED", GOODS_A, null),
                line("R2", "GK11Z13ND/2", "Double 3 Pin Socket", null, "6M|黑", "MATCHED", GOODS_B, null));

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ23/D", "DOUBLE 3 PIN SOCKET", "R1", false, true),
                new LearnedLine(GOODS_B, "GK11Z13ND/2", "Double 3 Pin Socket", "R2", false, true)), job);

        assertThat(plan.nameEn()).isEmpty();
        assertThat(plan.aliases()).as("描述对照有上下文区分, 仍然各学各的")
                .filteredOn(alias -> alias.kind() == AliasKind.DESCRIPTION).hasSize(4);
    }

    @Test
    void englishNameNeedsTheSavedNameToEqualTheJobEnglishDescription() {
        IntakeJobLines job = job(line("R1", "GZ23/D", "DOUBLE 3 PIN SOCKET", "两开插座", "", "MATCHED", GOODS_A, null));

        assertThat(SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ23/D", "两开插座", "R1", false, true)), job).nameEn())
                .as("保存的是中文描述, 不写英文名").isEmpty();
        assertThat(SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ23/D", " double  3 pin Socket. ", "R1", false, true)), job).nameEn())
                .as("规范化后一致也算(标点/大小写)").hasSize(1);
    }

    @Test
    void distinctiveEnglishRequiresTwoLatinWordsAndNoChinese() {
        assertThat(SalesLearningPlanner.distinctiveEnglish("DOUBLE SOCKET")).isTrue();
        assertThat(SalesLearningPlanner.distinctiveEnglish("SOCKET")).isFalse();
        assertThat(SalesLearningPlanner.distinctiveEnglish("13A 45")).isFalse();
        assertThat(SalesLearningPlanner.distinctiveEnglish("DOUBLE SOCKET 两开")).isFalse();
        assertThat(SalesLearningPlanner.distinctiveEnglish(null)).isFalse();
        assertThat(SalesLearningPlanner.distinctiveEnglish("A ".repeat(200))).isFalse();
    }

    @Test
    void linesWithoutGoodsOrUsableTextAreIgnoredAndNoClientMeansGlobalOnly() {
        IntakeJobLines job = job(line("R1", "GZ23/D", null, null, "", "MATCHED", GOODS_A, null));
        SalesLearningRequest withoutClient = new SalesLearningRequest("order", DOC, null, UUID.randomUUID(), null,
                List.of(new LearnedLine(GOODS_A, "GZ23/D", "  ", "R1", false, false),
                        new LearnedLine(null, "X", "Y", null, true, false)),
                Map.of(), UUID.randomUUID());

        SalesLearningPlanner.Plan plan = SalesLearningPlanner.plan(withoutClient, job);

        assertThat(plan.aliases()).singleElement()
                .satisfies(alias -> {
                    assertThat(alias.scope()).isEqualTo(AliasScope.GLOBAL);
                    assertThat(alias.kind()).isEqualTo(AliasKind.PART_NO);
                });
    }

    @Test
    void jobResultWithBrokenShapeDegradesToNoJob() {
        Map<String, Object> broken = new HashMap<>();
        broken.put("lines", "not-a-list");
        assertThat(IntakeJobLines.parse(broken).isEmpty()).isTrue();
        Map<String, Object> badLine = new HashMap<>();
        badLine.put("lines", List.of(Map.of("key", "R1", "selectedGoodsId", "not-a-uuid", "partNo", 12)));
        IntakeJobLines parsed = IntakeJobLines.parse(badLine);
        assertThat(parsed.line("R1").selectedGoodsId()).isNull();
        assertThat(parsed.line("R1").partNo()).isEqualTo("12");
        assertThat(IntakeJobLines.parse(null).isEmpty()).isTrue();
    }

    @Test
    void overlongContextSkipsTheLine() {
        IntakeJobLines job = job(line("R1", "GZ23/D", null, null, "Z".repeat(201), "MATCHED", GOODS_A, null));
        assertThat(SalesLearningPlanner.plan(request(
                new LearnedLine(GOODS_A, "GZ23/D", null, "R1", false, false)), job).isEmpty()).isTrue();
    }

    // ------------------------------------------------------------------

    private static SalesLearningRequest request(LearnedLine... lines) {
        return new SalesLearningRequest("quote", DOC, CLIENT, UUID.randomUUID(), UUID.randomUUID(),
                List.of(lines), Map.of(), UUID.randomUUID());
    }

    @SafeVarargs
    private static IntakeJobLines job(Map<String, Object>... lines) {
        Map<String, Object> result = new HashMap<>();
        result.put("schemaVersion", 2);
        result.put("lines", new ArrayList<>(List.of(lines)));
        return IntakeJobLines.parse(result);
    }

    private static Map<String, Object> line(String key, String partNo, String description, String descriptionAlt,
                                            String contextNorm, String status, UUID selected, String nameEnText) {
        Map<String, Object> line = new HashMap<>();
        line.put("key", key);
        line.put("partNo", partNo);
        line.put("description", description);
        line.put("descriptionAlt", descriptionAlt);
        line.put("contextNorm", contextNorm);
        line.put("status", status);
        line.put("selectedGoodsId", selected == null ? null : selected.toString());
        line.put("nameEnText", nameEnText);
        return line;
    }
}
