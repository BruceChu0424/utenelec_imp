package com.uten.imp.features.org.employee.reconcile;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.IdCardUtil;

import java.time.LocalDate;
import java.time.Period;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.UnaryOperator;

/**
 * 「身份证号修复建议」纯函数引擎（方案 4.4，只在服务端）：给定存量证件号和独立证据，
 * 生成至多 3 个候选修复值，按 log10 似然打分（{@link IdRepairScoring}），给出
 * 高/中/需人工/无候选 四档把握。
 *
 * <p>核心不变量「擦除可解 = 解出来不被校验码验证」：校验方程解出的改动（SUB、INS、
 * 未知位求解）构造即通过校验，校验码对它们没有验证作用，所以 {@code verified=false}，
 * 永远评不上「高」；只有由外部事实决定的改动（去分隔符、确定性字符映射、15 位升位、
 * 生日锚点、删除、对调）才是 {@code verified=true}，偶然通过校验的概率只有 1/11。
 *
 * <p>号码只在本类内存中流转，绝不写日志。判定全部复用 {@link IdCardUtil#check} /
 * {@link IdCardUtil#normalize}，不另写一套 GB 11643 规则。
 */
public final class IdRepairAdvisor {

    /** 建议档位：高=直接采用并预选；中=显示建议不预选；需人工=只给位置提示；无候选。 */
    public enum IdRepairTier { HIGH, MEDIUM, MANUAL, NONE }

    /**
     * 修复依据。生日/性别只有标注「独立」才参与打分（从存量号本身推导出来的值
     * 不是证据，方案 4.4.4）；{@code today} 供测试注入，null 视为业务今天；
     * {@code hmac}/{@code takenHashes} 用于剔除已被其他员工占用的号码，可 null。
     */
    public record IdRepairEvidence(LocalDate birth, boolean birthIndependent,
                                   String gender, boolean genderIndependent,
                                   LocalDate hireDate, LocalDate today,
                                   UnaryOperator<String> hmac, Set<String> takenHashes) {}

    /** 一个候选修复值。diffPositions 为 1-based，相对规范化（去分隔符）后的存量号。 */
    public record IdCandidate(String value, String op, double score, double p,
                              List<Integer> diffPositions, boolean verified) {}

    /** 建议结果：tier + 首选依据码 + 至多 3 个候选（p 降序，首选即建议值）。
     * tier 为 NONE 时 reasonCode 给守卫/问题码，basisCode 为 NONE 或 TYPE_HINT。 */
    public record IdSuggestion(IdRepairTier tier, String basisCode,
                               List<IdCandidate> candidates,
                               List<Integer> suspectPositions,
                               String reasonCode) {}

    // ---- op 取值（IdCandidate.op）----
    public static final String OP_NORMALIZE = "NORMALIZE";
    public static final String OP_MAP_CHAR = "MAP_CHAR";
    public static final String OP_UPGRADE15 = "UPGRADE15";
    public static final String OP_ANCHOR_BIRTH = "ANCHOR_BIRTH";
    public static final String OP_SUB = "SUB";
    public static final String OP_SWAP = "SWAP";
    public static final String OP_INS = "INS";
    public static final String OP_DEL = "DEL";
    public static final String OP_ERASE_SOLVED = "ERASE_SOLVED";

    // ---- basisCode 取值（首选候选的依据；NONE 档时为 NONE 或 TYPE_HINT）----
    public static final String BASIS_NORMALIZE = "NORMALIZE";
    public static final String BASIS_MAP_CHAR = "MAP_CHAR";
    public static final String BASIS_UPGRADE15 = "UPGRADE15";
    public static final String BASIS_BIRTH_ANCHOR = "BIRTH_ANCHOR";
    public static final String BASIS_DEL_REPEAT = "DEL_REPEAT";
    public static final String BASIS_SWAP = "SWAP";
    public static final String BASIS_CHECK_SOLVED = "CHECK_SOLVED";
    public static final String BASIS_INS_X = "INS_X";
    public static final String BASIS_ERASE_SOLVED = "ERASE_SOLVED";
    public static final String BASIS_TYPE_HINT = "TYPE_HINT";
    public static final String BASIS_NONE = "NONE";

    private static final IdRepairEvidence NO_EVIDENCE =
            new IdRepairEvidence(null, false, null, false, null, null, null, null);
    private static final String CHECK_ALPHABET = "0123456789X";
    /** 合法省级码（前 2 位）；46 海南、71 台湾、81-83 港澳按 2020 国标。 */
    private static final Set<Integer> PROVINCE_CODES = Set.of(
            11, 12, 13, 14, 15, 21, 22, 23, 31, 32, 33, 34, 35, 36, 37,
            41, 42, 43, 44, 45, 46, 50, 51, 52, 53, 54, 61, 62, 63, 64, 65, 71, 81, 82, 83);
    private static final int MIN_BIRTH_YEAR = 1940;
    private static final int MIN_HIRE_AGE = 16;
    private static final int MAX_HIRE_AGE = 70;

    /** 生成过程中的候选；score 已含加成与证据惩罚，是最终得分。 */
    private record Raw(String value, String op, String basis, double score,
                       boolean verified, List<Integer> diff) {}

    private IdRepairAdvisor() {}

    public static IdSuggestion suggest(String stored, IdRepairEvidence evidence) {
        IdRepairEvidence ev = evidence == null ? NO_EVIDENCE : evidence;
        LocalDate today = ev.today() == null ? BusinessTime.today() : ev.today();
        String birthText = ev.birth() == null ? null
                : ev.birth().format(DateTimeFormatter.BASIC_ISO_DATE);

        // ---- 4.4.2 保护规则（作用于规范化后的存量原文）----
        String s = IdCardUtil.normalize(stored);
        if (s == null) {
            return none(BASIS_NONE, ReconcileNotice.EMPTY.code());
        }
        if (s.indexOf('*') >= 0) {
            return none(BASIS_NONE, ReconcileNotice.MASKED.code());
        }
        if (isExcelTruncated(s)) {
            return none(BASIS_NONE, ReconcileNotice.EXCEL_TRUNCATED.code());
        }
        if (looksLikeForeignDocument(s)) {
            return none(BASIS_TYPE_HINT, ReconcileNotice.TYPE_HINT_FOREIGN.code());
        }
        if (s.length() == 18 && s.charAt(0) == '9' && IdCardUtil.check(s) == null) {
            return none(BASIS_TYPE_HINT, ReconcileNotice.TYPE_HINT_RESIDENT.code());
        }
        if (IdCardUtil.check(s) == null) {
            return none(BASIS_NONE, ReconcileNotice.ALREADY_VALID.code());
        }

        // ---- 清洗：去分隔符 + 确定性字符映射 ----
        String stripped = s.replaceAll("[\\s\\-_.'\"]", "");
        StringBuilder mapped = new StringBuilder(stripped.length());
        boolean charMapped = false;
        for (int i = 0; i < stripped.length(); i++) {
            char c = stripped.charAt(i);
            if ((c == '\u00D7' || c == '\u0425' || c == '\u03A7') && i == 17) {
                mapped.append('X');            // ×/西里尔Х/希腊Χ 只认第 18 位
                charMapped = true;
            } else if (c == 'O') {
                mapped.append('0');
                charMapped = true;
            } else if (c == 'I' || c == 'L' || c == '|') {
                mapped.append('1');
                charMapped = true;
            } else {
                mapped.append(c);
            }
        }
        String t = mapped.toString();

        // ---- 清洗后仍失败才继续守卫与邻域 ----
        boolean tValid = IdCardUtil.check(t) == null;
        if (!tValid) {
            if (isExcelTruncated(t)) {
                return none(BASIS_NONE, ReconcileNotice.EXCEL_TRUNCATED.code());
            }
            if (t.length() == 18) {
                if (!hasLegalProvince(t)) {
                    return none(BASIS_NONE, ReconcileNotice.REGION_UNKNOWN.code());
                }
                if ("000".equals(t.substring(14, 17))) {
                    return none(BASIS_NONE, ReconcileNotice.SEQUENCE_ZERO.code());
                }
            }
        }

        // ---- 候选生成 ----
        List<Raw> raws = new ArrayList<>();
        if (!t.equals(s) && tValid) {
            raws.add(raw(t, charMapped ? OP_MAP_CHAR : OP_NORMALIZE,
                    charMapped ? BASIS_MAP_CHAR : BASIS_NORMALIZE,
                    charMapped ? IdRepairScoring.BASE_MAP_CHAR : IdRepairScoring.BASE_NORMALIZE,
                    true, s.length() == t.length() ? positionDiff(s, t) : List.of(), ev, birthText));
        }
        if (t.matches("\\d{15}")) {
            String prefix = t.substring(0, 6) + "19" + t.substring(6);
            for (char c : CHECK_ALPHABET.toCharArray()) {
                String u = prefix + c;
                if (IdCardUtil.check(u) == null) {
                    raws.add(raw(u, OP_UPGRADE15, BASIS_UPGRADE15, IdRepairScoring.BASE_UPGRADE15,
                            true, List.of(7, 8, 18), ev, birthText));
                    break;
                }
            }
        }
        addBirthAnchorCandidate(raws, t, ev, birthText);
        if (!tValid) {
            switch (t.length()) {
                case 18 -> addEighteenCharNeighbourhood(raws, t, ev, birthText);
                case 17 -> addInsertions(raws, t, ev, birthText);
                case 19 -> addDeletions(raws, t, ev, birthText);
                default -> { }
            }
        }
        if (raws.isEmpty()) {
            return none(BASIS_NONE, ReconcileNotice.MULTIPLE_ERRORS.code());
        }

        // ---- 去重（同一号码保留得分最高的操作）后过滤 ----
        LinkedHashMap<String, Raw> best = new LinkedHashMap<>();
        for (Raw r : raws) {
            best.merge(r.value(), r, (a, b) -> b.score() > a.score() ? b : a);
        }
        List<Raw> kept = new ArrayList<>();
        for (Raw r : best.values()) {
            if (passesFilters(r, today, ev)) {
                kept.add(r);
            }
        }
        if (kept.isEmpty()) {
            return none(BASIS_NONE, ReconcileNotice.MULTIPLE_ERRORS.code());
        }

        // ---- softmax10（含 OTHER）与降序（稳定排序，同分按生成序）----
        double z = Math.pow(10, IdRepairScoring.OTHER);
        for (Raw r : kept) {
            z += Math.pow(10, r.score());
        }
        kept.sort((a, b) -> Double.compare(b.score(), a.score()));
        double pOther = Math.pow(10, IdRepairScoring.OTHER) / z;

        List<IdCandidate> top = new ArrayList<>(Math.min(3, kept.size()));
        for (Raw r : kept.subList(0, Math.min(3, kept.size()))) {
            top.add(new IdCandidate(r.value(), r.op(), r.score(), Math.pow(10, r.score()) / z,
                    r.diff(), r.verified()));
        }
        return grade(kept, top, pOther, ev, birthText);
    }

    // ------------------------------------------------------------------
    // 候选生成
    // ------------------------------------------------------------------

    /** 生日锚点：独立证据生日与生日段差距 ≤2 且变化落在窗口内部时，整段换成证据生日。 */
    private static void addBirthAnchorCandidate(List<Raw> raws, String t,
                                                IdRepairEvidence ev, String birthText) {
        if (ev.birth() == null || !ev.birthIndependent()
                || t.length() < 17 || t.length() > 19 || !isDigits(t.substring(0, 6))) {
            return;
        }
        int k = 8 + t.length() - 18;
        String seg = t.substring(6, 6 + k);
        String expected = birthText;
        if (seg.equals(expected) || levenshtein(seg, expected) > 2
                || !anchorChangeIsInterior(seg, expected, k)) {
            return;
        }
        String anchored = t.substring(0, 6) + expected + t.substring(6 + k);
        if (IdCardUtil.check(anchored) != null) {
            return;
        }
        List<Integer> diff = k == 8 ? positionDiff(t, anchored)
                : window(7, k == 7 ? 14 : 15);
        raws.add(raw(anchored, OP_ANCHOR_BIRTH, BASIS_BIRTH_ANCHOR,
                IdRepairScoring.BASE_ANCHOR_BIRTH, true, diff, ev, birthText));
    }

    /**
     * 锚点防误触：只认「变化落在生日窗口内部」的对齐。窗口边界上的差异（seg 去掉
     * 首位/末位正好等于证据生日、或在证据生日前后多一个字符）同样可能来自窗口外
     * 的错误——地区段少一位会把整个生日段左移、顺序段多一位会把它右移，此时锚点
     * 会拼出一个「生日对、地区或顺序错」却恰好过校验的号码（约 1/11），蒙特卡洛
     * 里出现过 p≥0.9 的错建议。
     *
     * <p>k=8 时首位（世纪位）单处差异仍放行：那正是「2990/1790 录错世纪位」的
     * 黄金形状，且此时锚点值必然等于第 7 位的 SUB 唯一解，候选池足够大（十来个
     * 同分 SUB），偶发的错锚点到不了 0.9；仅末位单处差异（第 14 位与顺序段互换
     * 的同形歧义）不放行，让位给单步邻域。
     */
    private static boolean anchorChangeIsInterior(String seg, String expected, int k) {
        if (k == 8) {
            int diffs = 0;
            int last = -1;
            for (int i = 0; i < 8; i++) {
                if (seg.charAt(i) != expected.charAt(i)) {
                    last = i;
                    diffs++;
                }
            }
            return diffs >= 2 || last <= 6;
        }
        if (k == 7) {
            return !seg.equals(expected.substring(1)) && !seg.equals(expected.substring(0, 7));
        }
        return !seg.endsWith(expected) && !seg.startsWith(expected);
    }

    private static void addEighteenCharNeighbourhood(List<Raw> raws, String t,
                                                     IdRepairEvidence ev, String birthText) {
        addEraseSolved(raws, t, ev, birthText);
        for (int i = 0; i < 17; i++) {
            char current = t.charAt(i);
            if (!isDigit(current)) {
                continue;
            }
            for (char d = '0'; d <= '9'; d++) {
                if (d == current) {
                    continue;
                }
                String v = t.substring(0, i) + d + t.substring(i + 1);
                if (IdCardUtil.check(v) == null) {
                    double score = IdRepairScoring.BASE_SUB
                            + (IdRepairScoring.confusablePair(current - '0', d - '0')
                                    ? IdRepairScoring.BONUS_CONFUSABLE : 0.0);
                    raws.add(raw(v, OP_SUB, BASIS_CHECK_SOLVED, score, false,
                            List.of(i + 1), ev, birthText));
                }
            }
        }
        char tail = t.charAt(17);
        if (isDigit(tail) || tail == 'X') {
            for (char c : CHECK_ALPHABET.toCharArray()) {
                if (c == tail) {
                    continue;
                }
                String v = t.substring(0, 17) + c;
                if (IdCardUtil.check(v) == null) {
                    raws.add(raw(v, OP_SUB, BASIS_CHECK_SOLVED, IdRepairScoring.BASE_SUB,
                            false, List.of(18), ev, birthText));
                }
            }
        }
        for (int i = 0; i < 16; i++) {
            char a = t.charAt(i);
            char b = t.charAt(i + 1);
            if (!isDigit(a) || !isDigit(b) || a == b) {
                continue;
            }
            String v = t.substring(0, i) + b + a + t.substring(i + 2);
            if (IdCardUtil.check(v) == null) {
                raws.add(raw(v, OP_SWAP, BASIS_SWAP, IdRepairScoring.BASE_SWAP, true,
                        List.of(i + 1, i + 2), ev, birthText));
            }
        }
    }

    /** 单个未知字符由校验方程解出（第 1..17 位唯一解，第 18 位直接算）；解不出就不给。 */
    private static void addEraseSolved(List<Raw> raws, String t,
                                       IdRepairEvidence ev, String birthText) {
        int unknown = -1;
        for (int i = 0; i < 18; i++) {
            char c = t.charAt(i);
            boolean acceptable = i < 17 ? isDigit(c) : isDigit(c) || c == 'X';
            if (!acceptable) {
                if (unknown >= 0) {
                    return;             // 两个以上未知位，无解
                }
                unknown = i;
            }
        }
        if (unknown < 0) {
            return;
        }
        if (unknown < 17) {
            for (char d = '0'; d <= '9'; d++) {
                String v = t.substring(0, unknown) + d + t.substring(unknown + 1);
                if (IdCardUtil.check(v) == null) {
                    raws.add(raw(v, OP_ERASE_SOLVED, BASIS_ERASE_SOLVED,
                            IdRepairScoring.BASE_ERASE_SOLVED, false,
                            List.of(unknown + 1), ev, birthText));
                }
            }
        } else {
            for (char c : CHECK_ALPHABET.toCharArray()) {
                String v = t.substring(0, 17) + c;
                if (IdCardUtil.check(v) == null) {
                    raws.add(raw(v, OP_ERASE_SOLVED, BASIS_ERASE_SOLVED,
                            IdRepairScoring.BASE_ERASE_SOLVED, false, List.of(18), ev, birthText));
                }
            }
        }
    }

    private static void addInsertions(List<Raw> raws, String t,
                                      IdRepairEvidence ev, String birthText) {
        for (int p = 0; p <= 17; p++) {
            for (char d = '0'; d <= '9'; d++) {
                String v = t.substring(0, p) + d + t.substring(p);
                if (IdCardUtil.check(v) == null) {
                    raws.add(raw(v, OP_INS, BASIS_CHECK_SOLVED, IdRepairScoring.BASE_INS,
                            false, List.of(p + 1), ev, birthText));
                }
            }
        }
        String withX = t + "X";
        if (IdCardUtil.check(withX) == null) {
            raws.add(raw(withX, OP_INS, BASIS_INS_X,
                    IdRepairScoring.BASE_INS + IdRepairScoring.BONUS_INS_TAIL_X,
                    false, List.of(18), ev, birthText));
        }
    }

    private static void addDeletions(List<Raw> raws, String t,
                                     IdRepairEvidence ev, String birthText) {
        for (int p = 0; p < 19; p++) {
            String v = t.substring(0, p) + t.substring(p + 1);
            if (IdCardUtil.check(v) != null) {
                continue;
            }
            boolean doubleClick = (p > 0 && t.charAt(p) == t.charAt(p - 1))
                    || (p < 18 && t.charAt(p) == t.charAt(p + 1));
            double score = IdRepairScoring.BASE_DEL
                    + (doubleClick ? IdRepairScoring.BONUS_DEL_REPEAT : 0.0);
            raws.add(raw(v, OP_DEL, doubleClick ? BASIS_DEL_REPEAT : BASIS_CHECK_SOLVED,
                    score, true, deletionWindow(p), ev, birthText));
        }
    }

    // ------------------------------------------------------------------
    // 打分、过滤、分级
    // ------------------------------------------------------------------

    private static Raw raw(String value, String op, String basis, double score,
                           boolean verified, List<Integer> diff,
                           IdRepairEvidence ev, String birthText) {
        if (ev.birthIndependent() && birthText != null
                && !birthText.equals(value.substring(6, 14))) {
            score += IdRepairScoring.EVIDENCE_BIRTH_MISMATCH;
        }
        if (ev.genderIndependent() && ev.gender() != null
                && !ev.gender().equals(genderOf(value))) {
            score += IdRepairScoring.EVIDENCE_GENDER_MISMATCH;
        }
        return new Raw(value, op, basis, score, verified, diff);
    }

    private static boolean passesFilters(Raw r, LocalDate today, IdRepairEvidence ev) {
        String v = r.value();
        if (!hasLegalProvince(v)) {
            return false;
        }
        int year = Integer.parseInt(v.substring(6, 10));
        if (year < MIN_BIRTH_YEAR || year > today.getYear() - 16) {
            return false;
        }
        if (ev.hireDate() != null) {
            int ageAtHire = Period.between(LocalDate.parse(v.substring(6, 14),
                    DateTimeFormatter.BASIC_ISO_DATE), ev.hireDate()).getYears();
            if (ageAtHire < MIN_HIRE_AGE || ageAtHire > MAX_HIRE_AGE) {
                return false;
            }
        }
        if (ev.hmac() != null && ev.takenHashes() != null
                && ev.takenHashes().contains(ev.hmac().apply(v))) {
            return false;
        }
        return true;
    }

    private static IdSuggestion grade(List<Raw> kept, List<IdCandidate> top,
                                      double pOther, IdRepairEvidence ev, String birthText) {
        IdCandidate first = top.get(0);
        Raw rawFirst = kept.get(0);
        boolean evidenceConsistent = isEvidenceConsistent(rawFirst, ev, birthText);
        if (first.p() >= IdRepairScoring.P_HIGH && first.verified() && evidenceConsistent) {
            return new IdSuggestion(IdRepairTier.HIGH, basisOf(rawFirst), top, List.of(), null);
        }
        double second = Math.max(top.size() > 1 ? top.get(1).p() : 0.0, pOther);
        if (first.p() >= IdRepairScoring.P_MEDIUM && first.p() >= IdRepairScoring.MARGIN_FACTOR * second) {
            return new IdSuggestion(IdRepairTier.MEDIUM, basisOf(rawFirst), top, List.of(), null);
        }
        if (kept.size() == 1) {
            // 单候选但没到「中」的门槛：弱建议，显示但不预选。
            return new IdSuggestion(IdRepairTier.MEDIUM, basisOf(rawFirst), top, List.of(), null);
        }
        List<Integer> suspect = List.of();
        if (kept.size() > 3) {
            TreeSet<Integer> union = new TreeSet<>();
            boolean noEvidence = (birthText == null || !ev.birthIndependent())
                    && (ev.gender() == null || !ev.genderIndependent());
            for (Raw r : kept) {
                if (noEvidence || isEvidenceConsistent(r, ev, birthText)) {
                    union.addAll(r.diff());
                }
            }
            suspect = List.copyOf(union);
        }
        return new IdSuggestion(IdRepairTier.MANUAL, basisOf(rawFirst), top, suspect, null);
    }

    private static boolean isEvidenceConsistent(Raw r, IdRepairEvidence ev, String birthText) {
        if (ev.birthIndependent() && birthText != null
                && !birthText.equals(r.value().substring(6, 14))) {
            return false;
        }
        return !ev.genderIndependent() || ev.gender() == null
                || ev.gender().equals(genderOf(r.value()));
    }

    private static String basisOf(Raw r) {
        return r.basis();
    }

    private static IdSuggestion none(String basisCode, String reasonCode) {
        return new IdSuggestion(IdRepairTier.NONE, basisCode, List.of(), List.of(), reasonCode);
    }

    // ------------------------------------------------------------------
    // 守卫与小工具
    // ------------------------------------------------------------------

    /** ^\d{15}000$ 且校验不过：Excel 把号码列当数字丢掉末三位的典型形状。 */
    private static boolean isExcelTruncated(String v) {
        return v.matches("\\d{15}000") && IdCardUtil.check(v) != null;
    }

    /** 护照 E/G/P+8 位数字、港澳 H/M+8 或 10 位数字的形状（已规范化为大写）。 */
    private static boolean looksLikeForeignDocument(String v) {
        return v.matches("[EGP]\\d{8}") || v.matches("[HM](\\d{8}|\\d{10})");
    }

    private static boolean hasLegalProvince(String v) {
        if (v.length() < 2 || !isDigit(v.charAt(0)) || !isDigit(v.charAt(1))) {
            return false;
        }
        return PROVINCE_CODES.contains((v.charAt(0) - '0') * 10 + (v.charAt(1) - '0'));
    }

    /** 候选已过校验，第 17 位奇偶直接可得：奇=男，偶=女（与 IdCardUtil.gender 一致）。 */
    private static String genderOf(String validId) {
        return (validId.charAt(16) - '0') % 2 == 1 ? "male" : "female";
    }

    private static boolean isDigit(char c) {
        return c >= '0' && c <= '9';
    }

    private static boolean isDigits(String s) {
        for (int i = 0; i < s.length(); i++) {
            if (!isDigit(s.charAt(i))) {
                return false;
            }
        }
        return true;
    }

    private static List<Integer> positionDiff(String a, String b) {
        List<Integer> diff = new ArrayList<>();
        for (int i = 0; i < a.length(); i++) {
            if (a.charAt(i) != b.charAt(i)) {
                diff.add(i + 1);
            }
        }
        return List.copyOf(diff);
    }

    private static List<Integer> window(int from, int to) {
        List<Integer> range = new ArrayList<>();
        for (int p = from; p <= to; p++) {
            range.add(p);
        }
        return List.copyOf(range);
    }

    /** 删除 0-based 第 p 位后的改动位窗口（1-based，相对原 19 位串，截到 18）。 */
    private static List<Integer> deletionWindow(int p) {
        if (p + 1 > 18) {
            return List.of();           // 删的是末尾第 19 位，前 18 位原样
        }
        return p + 2 <= 18 ? List.of(p + 1, p + 2) : List.of(p + 1);
    }

    /** 经典 Levenshtein 距离，串长 ≤10，两行滚动数组足够。 */
    private static int levenshtein(String a, String b) {
        int[] prev = new int[b.length() + 1];
        int[] curr = new int[b.length() + 1];
        for (int j = 0; j <= b.length(); j++) {
            prev[j] = j;
        }
        for (int i = 1; i <= a.length(); i++) {
            curr[0] = i;
            for (int j = 1; j <= b.length(); j++) {
                int cost = a.charAt(i - 1) == b.charAt(j - 1) ? 0 : 1;
                curr[j] = Math.min(Math.min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
            }
            int[] swap = prev;
            prev = curr;
            curr = swap;
        }
        return prev[b.length()];
    }
}
