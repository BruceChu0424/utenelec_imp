package com.uten.imp.features.org.employee.reconcile;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.features.org.employee.reconcile.IdRepairAdvisor.IdCandidate;
import com.uten.imp.features.org.employee.reconcile.IdRepairAdvisor.IdRepairEvidence;
import com.uten.imp.features.org.employee.reconcile.IdRepairAdvisor.IdRepairTier;
import com.uten.imp.features.org.employee.reconcile.IdRepairAdvisor.IdSuggestion;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.List;
import java.util.Random;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

/**
 * 4.4.8 黄金用例 + 保护规则 + 哈希剔除 + 蒙特卡洛精度。基准号全部编造，
 * 校验码已按 GB 11643 独立复核（测试外核算）。
 */
class IdRepairAdvisorTest {

    /** F1：男，1990-03-07，也是 15 位 442000900307123 的升位结果。 */
    private static final String F1 = "44200019900307123X";
    /** F2：女，1985-11-12。 */
    private static final String F2 = "450322198511122646";
    /** FX：女，1988-05-16。 */
    private static final String FX = "45032219880516012X";

    private static final LocalDate TODAY = LocalDate.of(2026, 10, 6);
    private static final IdRepairEvidence NO_EVIDENCE =
            new IdRepairEvidence(null, false, null, false, null, TODAY, null, null);

    private static IdRepairEvidence evidence(LocalDate birth, String gender) {
        return new IdRepairEvidence(birth, true, gender, true, null, TODAY, null, null);
    }

    private static IdSuggestion suggest(String stored, IdRepairEvidence ev) {
        return IdRepairAdvisor.suggest(stored, ev);
    }

    // ------------------------------------------------------------------
    // 黄金用例（方案 4.4.8）
    // ------------------------------------------------------------------

    @Test
    void separatorNoiseIsNormalizedIntoHighSuggestion() {
        IdSuggestion suggestion = suggest("442000 19900307 123X", NO_EVIDENCE);
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.HIGH);
        assertThat(suggestion.candidates()).hasSize(1);
        IdCandidate top = suggestion.candidates().getFirst();
        assertThat(top.value()).isEqualTo(F1);
        assertThat(top.op()).isEqualTo("NORMALIZE");
        assertThat(suggestion.basisCode()).isEqualTo("NORMALIZE");
        assertThat(top.verified()).isTrue();
        assertThat(top.p()).isGreaterThanOrEqualTo(0.90);
    }

    @Test
    void multiplicationSignAtTailIsMappedToXAsHigh() {
        IdSuggestion suggestion = suggest("45032219880516012\u00D7", NO_EVIDENCE);
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.HIGH);
        IdCandidate top = suggestion.candidates().getFirst();
        assertThat(top.value()).isEqualTo(FX);
        assertThat(top.op()).isEqualTo("MAP_CHAR");
        assertThat(suggestion.basisCode()).isEqualTo("MAP_CHAR");
        assertThat(top.verified()).isTrue();
        assertThat(top.diffPositions()).containsExactly(18);
    }

    @Test
    void letterOInsideDigitsIsMappedToZeroAsHigh() {
        IdSuggestion suggestion = suggest("4420001990O307123X", NO_EVIDENCE);
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.HIGH);
        IdCandidate top = suggestion.candidates().getFirst();
        assertThat(top.value()).isEqualTo(F1);
        assertThat(top.op()).isEqualTo("MAP_CHAR");
        assertThat(top.diffPositions()).containsExactly(11);
    }

    @Test
    void fifteenDigitNumberIsUpgradedWithIndependentBirthEvidence() {
        IdSuggestion suggestion = suggest("442000900307123",
                evidence(LocalDate.of(1990, 3, 7), "male"));
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.HIGH);
        IdCandidate top = suggestion.candidates().getFirst();
        assertThat(top.value()).isEqualTo(F1);
        assertThat(top.op()).isEqualTo("UPGRADE15");
        assertThat(suggestion.basisCode()).isEqualTo("UPGRADE15");
        assertThat(top.verified()).isTrue();
        assertThat(top.diffPositions()).containsExactly(7, 8, 18);
    }

    @Test
    void nineteenCharDuplicatedNineResolvesToHighWithEvidence() {
        IdSuggestion suggestion = suggest("442000199900307123X",
                evidence(LocalDate.of(1990, 3, 7), "male"));
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.HIGH);
        assertThat(suggestion.candidates().getFirst().value()).isEqualTo(F1);
        assertThat(suggestion.candidates().getFirst().p()).isGreaterThan(0.99);
    }

    @Test
    void birthAnchorIsHighWithEvidenceButOnlyMediumWhenSolvedAlone() {
        IdRepairEvidence withBirth = evidence(LocalDate.of(1985, 11, 12), "female");
        IdSuggestion anchored = suggest("450322198521122646", withBirth);
        assertThat(anchored.tier()).isEqualTo(IdRepairTier.HIGH);
        assertThat(anchored.candidates()).hasSize(1);
        assertThat(anchored.candidates().getFirst().value()).isEqualTo(F2);
        assertThat(anchored.basisCode()).isEqualTo("BIRTH_ANCHOR");
        assertThat(anchored.candidates().getFirst().verified()).isTrue();

        // 无证据：同一候选只能靠单步 SUB 解出，属于「解出来」，最多「中」。
        IdSuggestion solved = suggest("450322198521122646", NO_EVIDENCE);
        assertThat(solved.tier()).isEqualTo(IdRepairTier.MEDIUM);
        assertThat(solved.candidates().getFirst().value()).isEqualTo(F2);
        assertThat(solved.candidates().getFirst().verified()).isFalse();
    }

    @Test
    void centuryTyposAreAnchoredBackToHigh() {
        IdRepairEvidence ev = evidence(LocalDate.of(1990, 3, 7), "male");
        assertThat(suggest("44200029900307123X", ev).tier()).isEqualTo(IdRepairTier.HIGH);
        assertThat(suggest("44200029900307123X", ev).candidates().getFirst().value()).isEqualTo(F1);
        assertThat(suggest("44200017900307123X", ev).tier()).isEqualTo(IdRepairTier.HIGH);
        assertThat(suggest("44200017900307123X", ev).candidates().getFirst().value()).isEqualTo(F1);
    }

    @Test
    void dayMonthSwapOutsideSingleStepIsAnchoredToHigh() {
        IdSuggestion suggestion = suggest("44200019900703123X",
                evidence(LocalDate.of(1990, 3, 7), "male"));
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.HIGH);
        assertThat(suggestion.candidates().getFirst().value()).isEqualTo(F1);
        assertThat(suggestion.basisCode()).isEqualTo("BIRTH_ANCHOR");
    }

    @Test
    void missingBirthDigitInSeventeenCharsIsAnchoredToHigh() {
        IdSuggestion suggestion = suggest("45032219851122646",
                evidence(LocalDate.of(1985, 11, 12), "female"));
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.HIGH);
        IdCandidate top = suggestion.candidates().getFirst();
        assertThat(top.value()).isEqualTo(F2);
        assertThat(top.op()).isEqualTo("ANCHOR_BIRTH");
        assertThat(top.verified()).isTrue();
        assertThat(top.p()).isGreaterThanOrEqualTo(0.95);
    }

    @Test
    void lostTailXIsMediumInsXWithKnownProbability() {
        IdSuggestion suggestion = suggest("45032219880516012",
                evidence(LocalDate.of(1988, 5, 16), "female"));
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.MEDIUM);
        IdCandidate top = suggestion.candidates().getFirst();
        assertThat(top.value()).isEqualTo(FX);
        assertThat(top.op()).isEqualTo("INS");
        assertThat(suggestion.basisCode()).isEqualTo("INS_X");
        assertThat(top.verified()).isFalse();
        assertThat(top.p()).isCloseTo(0.72, within(0.03));
        assertThat(top.diffPositions()).containsExactly(18);
        assertThat(suggestion.candidates()).hasSize(3);
    }

    @Test
    void tailXRecordedAsOneNeedsManualWithSuspectPositions() {
        IdSuggestion suggestion = suggest("442000199003071231",
                evidence(LocalDate.of(1990, 3, 7), "male"));
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.MANUAL);
        assertThat(suggestion.candidates())
                .extracting(IdCandidate::value)
                .doesNotContain(F1);
        assertThat(suggestion.suspectPositions()).isNotEmpty();
        assertThat(suggestion.suspectPositions())
                .isSubsetOf(2, 3, 4, 5, 6, 15, 16, 17, 18);
    }

    @Test
    void takenHashRemovesTruthFromEveryCandidate() {
        IdRepairEvidence ev = new IdRepairEvidence(LocalDate.of(1990, 3, 7), true, "male", true,
                null, TODAY, value -> "h:" + value, Set.of("h:" + F1));
        IdSuggestion suggestion = suggest("442000199003071231", ev);
        assertThat(suggestion.candidates())
                .extracting(IdCandidate::value)
                .doesNotContain(F1)
                .isNotEmpty();
    }

    // ------------------------------------------------------------------
    // 保护规则（方案 4.4.2）
    // ------------------------------------------------------------------

    @Test
    void excelTruncatedShapeHasNoCandidates() {
        IdSuggestion suggestion = suggest("442000199003071000", NO_EVIDENCE);
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.NONE);
        assertThat(suggestion.reasonCode()).isEqualTo("EXCEL_TRUNCATED");
        assertThat(suggestion.candidates()).isEmpty();
    }

    @Test
    void sequenceZeroHasNoCandidates() {
        IdSuggestion suggestion = suggest("44200019900307000X", NO_EVIDENCE);
        assertThat(suggestion.tier()).isEqualTo(IdRepairTier.NONE);
        assertThat(suggestion.reasonCode()).isEqualTo("SEQUENCE_ZERO");
    }

    @Test
    void passportLikeNumbersOnlyHintDocumentType() {
        for (String stored : List.of("E12345678", "H12345678")) {
            IdSuggestion suggestion = suggest(stored, NO_EVIDENCE);
            assertThat(suggestion.tier()).isEqualTo(IdRepairTier.NONE);
            assertThat(suggestion.reasonCode()).isEqualTo("TYPE_HINT_FOREIGN");
            assertThat(suggestion.basisCode()).isEqualTo("TYPE_HINT");
        }
    }

    @Test
    void emptyMaskedAndAlreadyValidGuards() {
        assertThat(suggest(null, NO_EVIDENCE).reasonCode()).isEqualTo("EMPTY");
        assertThat(suggest("   ", NO_EVIDENCE).reasonCode()).isEqualTo("EMPTY");
        assertThat(suggest("45032219****16012X", NO_EVIDENCE).reasonCode()).isEqualTo("MASKED");
        IdSuggestion valid = suggest(F1, NO_EVIDENCE);
        assertThat(valid.tier()).isEqualTo(IdRepairTier.NONE);
        assertThat(valid.reasonCode()).isEqualTo("ALREADY_VALID");
    }

    // ------------------------------------------------------------------
    // 擦除求解
    // ------------------------------------------------------------------

    @Test
    void erasedUnknownDigitIsSolvedButNeverVerified() {
        // F1 的第 12 位（生日段里的 3）被未知符顶替，应由校验方程唯一解出。
        // 不带生日证据：一旦带独立生日，同一号码会以更高分的 ANCHOR_BIRTH 胜出去重。
        IdSuggestion suggestion = suggest("44200019900?07123X", NO_EVIDENCE);
        assertThat(suggestion.candidates()).hasSize(1);
        IdCandidate solved = suggestion.candidates().getFirst();
        assertThat(solved.value()).isEqualTo(F1);
        assertThat(solved.op()).isEqualTo("ERASE_SOLVED");
        assertThat(solved.verified()).isFalse();
        assertThat(solved.diffPositions()).containsExactly(12);
        assertThat(suggestion.tier()).isIn(IdRepairTier.MEDIUM, IdRepairTier.MANUAL);
    }

    // ------------------------------------------------------------------
    // 蒙特卡洛：固定种子 2000 个随机合法号，按 Verhoeff 比例注入单处错误，
    // 证据 = 真实生日 + 真实性别（均独立）。凡评为「高」的建议必须 100% 正确。
    // ------------------------------------------------------------------

    @Test
    void monteCarloHighSuggestionsAreAlwaysCorrect() {
        Random rnd = new Random(20261006L);
        int highCount = 0;
        for (int i = 0; i < 2000; i++) {
            String truth = randomValidId(rnd);
            String stored = injectSingleError(truth, rnd);
            IdSuggestion suggestion = suggest(stored, new IdRepairEvidence(
                    LocalDate.of(Integer.parseInt(truth.substring(6, 10)),
                            Integer.parseInt(truth.substring(10, 12)),
                            Integer.parseInt(truth.substring(12, 14))),
                    true,
                    (truth.charAt(16) - '0') % 2 == 1 ? "male" : "female",
                    true, null, TODAY, null, null));
            assertThat(suggestion.tier()).isNotNull();
            if (suggestion.tier() == IdRepairTier.HIGH) {
                highCount++;
                assertThat(suggestion.candidates().getFirst().value())
                        .as("high suggestion must equal the injected truth for stored value")
                        .isEqualTo(truth);
            }
        }
        assertThat(highCount).isGreaterThan(300);
    }

    private static final int[] PROVINCES = {
            11, 12, 13, 14, 15, 21, 22, 23, 31, 32, 33, 34, 35, 36, 37,
            41, 42, 43, 44, 45, 46, 50, 51, 52, 53, 54, 61, 62, 63, 64, 65, 71, 81, 82, 83};

    /** 合法省级码 + 4 位市县码 + 1950..今年-20 生日 + 非零顺序码 + 按校验规则算出的末位。 */
    private static String randomValidId(Random rnd) {
        int province = PROVINCES[rnd.nextInt(PROVINCES.length)];
        int regionSuffix = rnd.nextInt(10000);
        int year = 1950 + rnd.nextInt(TODAY.getYear() - 20 - 1950 + 1);
        int month = 1 + rnd.nextInt(12);
        int day = 1 + rnd.nextInt(LocalDate.of(year, month, 1).lengthOfMonth());
        int sequence = 1 + rnd.nextInt(999);
        String prefix = String.format("%02d%04d%04d%02d%02d%03d",
                province, regionSuffix, year, month, day, sequence);
        for (char c : "0123456789X".toCharArray()) {
            String candidate = prefix + c;
            if (IdCardUtil.check(candidate) == null) {
                return candidate;
            }
        }
        throw new IllegalStateException("unreachable: checksum alphabet covers all residues");
    }

    /** 单处错误：79% 单字替换 / 10% 相邻对调 / 5% 多打一位 / 5% 少打一位 / 1% 双击重复。 */
    private static String injectSingleError(String truth, Random rnd) {
        double roll = rnd.nextDouble();
        if (roll < 0.79) {
            int p = rnd.nextInt(17);
            int d = rnd.nextInt(10);
            while (d == truth.charAt(p) - '0') {
                d = rnd.nextInt(10);
            }
            return truth.substring(0, p) + d + truth.substring(p + 1);
        }
        if (roll < 0.89) {
            int p = rnd.nextInt(16);
            while (truth.charAt(p) == truth.charAt(p + 1)) {
                p = rnd.nextInt(16);
            }
            return truth.substring(0, p) + truth.charAt(p + 1) + truth.charAt(p) + truth.substring(p + 2);
        }
        if (roll < 0.94) {
            int p = rnd.nextInt(19);
            return truth.substring(0, p) + rnd.nextInt(10) + truth.substring(p);
        }
        if (roll < 0.99) {
            int p = rnd.nextInt(18);
            return truth.substring(0, p) + truth.substring(p + 1);
        }
        int p = rnd.nextInt(17);
        return truth.substring(0, p) + truth.charAt(p) + truth.substring(p);
    }

    // ------------------------------------------------------------------
    // 提示文案硬约束
    // ------------------------------------------------------------------

    @Test
    void noticeMessagesNeverContainSixConsecutiveDigits() {
        assertThat(ReconcileNotice.values()).extracting(ReconcileNotice::code).doesNotHaveDuplicates();
        for (ReconcileNotice notice : ReconcileNotice.values()) {
            String message = notice.message("张三", "2026-10-07 23:59");
            assertThat(message)
                    .as("notice %s must not carry 6+ consecutive digits", notice.code())
                    .doesNotMatch(".*\\d{6,}.*")
                    .isNotBlank();
        }
        assertThat(ReconcileNotice.CLAIMED_BY_OTHER.message("张三", "2026-10-07"))
                .contains("张三")
                .contains("2026-10-07")
                .doesNotContain("{name}")
                .doesNotContain("{until}");
    }
}
