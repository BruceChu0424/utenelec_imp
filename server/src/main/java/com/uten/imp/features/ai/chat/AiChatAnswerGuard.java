package com.uten.imp.features.ai.chat;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * ADR-150 post-answer guard. A model reply may only present facts that exist in the sources it was
 * given: every number and business code must appear in the sources or the user's own words, every
 * "colour = status" line must be a pair the page itself reported (with its row count), no
 * first-person completion claim ("已保存/已提交 ...") is allowed, links, bare domains and markup are
 * removed and the length is bounded. A rejected reply is replaced by deterministic rendering.
 *
 * <p>ADR-152: conversation memory is a separate, weaker source. A number or code found only in earlier
 * turns (not in the current page, sources or question) may be repeated only where the reply says it comes
 * from the earlier conversation: the same line must carry a memory marker ("刚才说的 / 之前查到的 / 上一页的 /
 * earlier ..."), or, for a list item, the line that introduces the list. A time phrase such as "发货之前" or
 * "before shipping" is not a memory marker. So remembered values are never presented as what the current
 * page shows, even when another line of the reply mentions the earlier conversation.
 */
final class AiChatAnswerGuard {
    static final int MAX_REPLY = 4000;
    private static final Pattern MARKDOWN_LINK = Pattern.compile("\\[([^\\]\\n]{1,200})\\]\\([^)\\s]{1,2000}\\)");
    private static final Pattern URL = Pattern.compile("(?i)(?:[a-z][a-z0-9+.-]{1,15}://|www\\.)[^\\s)\uFF09\\]]*");
    /**
     * A bare host ("pay-verify.cn/login"): labels joined by dots ending in a common or two-letter
     * top-level domain, optional port and path. File names (".xlsx", ".pdf") are not hosts.
     */
    private static final Pattern HOST = Pattern.compile("(?i)(?<![A-Za-z0-9@._-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+"
            + "(?:com|net|org|info|biz|top|xyz|site|online|shop|store|vip|club|app|dev|io|ai|co|me|cc|tv|link|click|live"
            + "|pro|tech|cloud|asia|mobi|work|wang|ltd|group|gov|edu|[a-z]{2})(?![A-Za-z0-9-])(?::\\d{2,5})?"
            + "(?:/[A-Za-z0-9._~%!$&'*+,;=:@/?#-]*)?");
    private static final Pattern TAG = Pattern.compile("<[^<>\\n]{1,300}>");
    private static final Pattern CODE = Pattern.compile("(?<![A-Za-z0-9])[A-Za-z]{1,10}[-_]?[0-9][A-Za-z0-9_-]{1,40}");
    private static final Pattern NUMBER = Pattern.compile("\\d+(?:[.,]\\d+)*");
    private static final Pattern LIST_MARKER = Pattern.compile("(?m)^\\s*(?:[-*•]\\s*)?\\d{1,2}(?:[.、)\uFF09]|\\s*[.、])");
    private static final Pattern REMAINING = Pattern.compile("还有\\s*\\d+\\s*(?:项|条)|另外\\s*\\d+\\s*(?:项|条)");
    private static final String DONE_VERBS =
            "(?:保存|提交|审核|审批|删除|下单|下达|授权|开通|发出|发送|入库|出库|付款|过账|作废|执行|修改|改好|改成|填好|填入|确认|完成|处理)";
    /**
     * The assistant claiming it did something: "我已保存", "已为你提交", a sentence that is only "保存好了。", "I have
     * submitted". A rule explanation ("已审核的入库单不能直接改", "审核完成了才会入库", "the order has been
     * submitted, so ...") is not a claim.
     */
    private static final Pattern FIRST_PERSON_DONE = Pattern.compile(
            "(?:我|帮你|为你|替你)\\s*(?:已经|已|刚刚|刚才|成功)\\s*" + DONE_VERBS
                    + "|(?:已经?(?:为你|帮你|替你))\\s*" + DONE_VERBS
                    + "|(?:^|[。！!；;\\n])\\s*(?:好的?[，,]\\s*)?[^。！!；;，,\\n]{0,8}?(?:保存|提交|审核|改|填|处理|设置|修改|授权|开通)"
                    + "(?:好了|成功了|完毕|完成了)\\s*(?:[。！!]|$)"
                    + "|(?i:\\b(?:I|we)\\s+(?:have\\s+|'ve\\s+)?(?:already\\s+|just\\s+)?(?:saved|submitted|approved|deleted|granted|posted|executed"
                    + "|changed|updated)\\b)|(?i:\\bhas\\s+been\\s+(?:saved|submitted|approved|deleted|granted|posted|executed)\\s+for\\s+you\\b)");
    /**
     * "颜色 = 状态 = 含义 (N 行)" or "颜色 = 状态 (N)", optionally after a list marker and a "列名:" prefix.
     * Group 1 is the colour side, 2 the status side, 3 the rest of the line.
     */
    private static final Pattern COLOUR_LINE = Pattern.compile(
            "(?m)^\\s*(?:[-*•]\\s*)?(?:\\d{1,2}[.、)\uFF09]\\s*)?(?:[^=\\n:：]{1,40}[:：]\\s*)?"
                    + "([^=\\n:：]{1,16}?)\\s*[=＝]\\s*([^=＝\\n]{1,100}?)\\s*(?:[=＝]\\s*([^\\n]*))?$");
    private static final Pattern COUNT = Pattern.compile("[(\uFF08]\\s*(\\d{1,8})\\s*(?:行|个|项|条)?\\s*[)\uFF09]");
    /** Colour words the page and the conventions use; anything else on the left is not a colour claim. */
    private static final Set<String> COLOUR_WORDS = Set.of("灰", "蓝", "绿", "黄", "琥珀", "红", "品红", "紫", "青", "青绿",
            "橙", "橘", "粉", "棕", "黑", "白");
    /**
     * A bare completion statement on a page or tool answer: "已保存。", "好的，已提交". "已审核的单据", "单据已提交，不能再改"
     * or "如果已审核" describe a state or a rule and are not claims.
     */
    private static final Pattern DONE_PHRASE = Pattern.compile(
            "(?:^|[。！!；;，,\\n])[^。！!；;，,\\n]{0,8}?(已(?:经)?(?:为你|帮你|替你)?(?:保存|提交|审核|审批|删除|下单|下达|授权|开通|过账|作废"
                    + "|付款|执行))(?:了|好|成功|完成|完毕)?\\s*(?=[。！!]|$)"
                    + "|(?i:(?:^|[.!?\\n]\\s*)(?:the\\s+\\w+|it|this\\s+\\w+|your\\s+\\w+)\\s+has\\s+been\\s+(?:saved|submitted|approved|deleted|granted"
                    + "|posted|executed)\\s*[.!]?\\s*$)");

    /**
     * Words that mark a statement as coming from the earlier conversation. "之前/此前/前面/上次" count only when
     * they refer to something said, looked up or another page ("之前说的", "前面列出的", "上次查到", "之前的页面"),
     * never as a time phrase ("发货之前", "在此之前"); English "before" never counts.
     */
    static final Pattern MEMORY_MARKER = Pattern.compile(
            "刚才|刚刚|上一轮|上一条|上一个问题|上个问题|上一页|上个页面|上一个页面|你问过|你提到|你说过|对话(?:中|里)"
                    + "|(?:之前|此前|先前|前面|上次|早先)的?(?:对话|回答|答复|问题|提问|查询|结果|页面|说|讲|提|问|查|列|答|聊|给出|看到)"
                    + "|(?i:\\bearlier\\b(?!\\s+than)|\\bpreviously\\b|\\bprevious\\s+(?:answer|question|turn|reply|message)"
                    + "|\\byou\\s+(?:asked|mentioned)\\b|\\bas\\s+(?:mentioned|discussed)\\b)"
                    + "|아까|앞서|이전\\s*(?:대화|답변|질문)");
    private static final Pattern LIST_ITEM = Pattern.compile("^\\s*(?:[-*•]|\\d{1,2}(?:[.、)\uFF09]|\\s*[.、]))");

    record Verdict(boolean accepted, String reply, List<String> problems) {}

    /** One colour the page reported: legend entry (count = rows) or badge (count = its number). */
    record ColourFact(String colour, String status, Integer count) {}

    private AiChatAnswerGuard() {}

    static Verdict check(String reply, String evidence, String question) {
        return check(reply, evidence, question, List.of());
    }

    /**
     * @param reply     model text
     * @param evidence  concatenated source text the model received (page snapshot, guide, knowledge, facts)
     * @param question  the user's own words (numbers the user typed may be repeated)
     * @param colours   the page's own colour/status pairs; when present, colour lines are checked as pairs
     *                  against them only (the knowledge text lists every colour and generic status, so a
     *                  word-by-word check against the evidence would accept a swapped pair)
     */
    static Verdict check(String reply, String evidence, String question, List<ColourFact> colours) {
        return check(reply, evidence, "", question, colours, MAX_REPLY);
    }

    /**
     * @param memory   earlier-turn text carried as conversation memory (may be empty)
     * @param maxChars longest reply kept (longer replies are cut at a line break)
     */
    static Verdict check(String reply, String evidence, String memory, String question, List<ColourFact> colours,
                         int maxChars) {
        return check(reply, evidence, memory, question, colours, maxChars, evidence, null);
    }

    /**
     * ADR-153 full check.
     *
     * @param visible    text the user can already see (page snapshot, guide, tool facts): identifiers found there
     *                   are not internal names; code blocks, commands, SQL, addresses and paths never pass
     * @param derivation for a rule explanation, the numbers it may compute from the user's own numbers and the
     *                   rule sources; null keeps every new number a problem (page and tool data)
     */
    static Verdict check(String reply, String evidence, String memory, String question, List<ColourFact> colours,
                         int maxChars, String visible, Derivation derivation) {
        List<String> problems = new ArrayList<>();
        if (reply != null) {
            for (String kind : AiChatInternalContent.problems(reply, (visible == null ? "" : visible) + "\n"
                    + (question == null ? "" : question))) {
                problems.add("INTERNAL:" + kind);
            }
        }
        if (reply == null || reply.isBlank()) return new Verdict(false, "", List.of("EMPTY"));
        // Markup first: a tag may wrap a link, and a stripped link must not leave half a tag behind.
        String text = TAG.matcher(MARKDOWN_LINK.matcher(reply).replaceAll("$1")).replaceAll("");
        text = HOST.matcher(URL.matcher(text).replaceAll("")).replaceAll("");
        text = text.replaceAll("[\\p{Cf}]+", "").replaceAll("[\\p{Cc}&&[^\\n]]+", " ")
                .replaceAll("(?m)^#{1,6}\\s*", "").replace("**", "").replaceAll("\\n{3,}", "\n\n").strip();
        if (text.isEmpty()) return new Verdict(false, "", List.of("EMPTY"));
        String source = (evidence == null ? "" : evidence) + "\n" + (question == null ? "" : question);
        String remembered = memory == null ? "" : memory;
        String lowerSource = source.toLowerCase(Locale.ROOT);
        String lowerMemory = remembered.toLowerCase(Locale.ROOT);
        Set<String> known = numbers(source);
        Set<String> recalled = numbers(remembered);
        // A number the reply itself works out on an arithmetic line ("2.5 kg ÷ 200 = 0.0125 kg = 12.5 g") may also be
        // stated on the summary line ("每个约 12.5 克"), wherever that line comes.
        Set<String> established = new HashSet<>();
        if (derivation != null) {
            for (Line line : lines(text)) {
                if (!derivation.showsArithmetic(line.text())) continue;
                Matcher numbers = NUMBER.matcher(CODE.matcher(line.text()).replaceAll(" "));
                while (numbers.find()) {
                    if (derivation.allows(numbers.group(), line.text())) established.add(normalize(numbers.group()));
                }
            }
        }
        for (Line line : lines(text)) {
            String scan = REMAINING.matcher(LIST_MARKER.matcher(line.text()).replaceAll(" ")).replaceAll(" ");
            Matcher codes = CODE.matcher(scan);
            StringBuilder withoutCodes = new StringBuilder();
            while (codes.find()) {
                String code = codes.group().toLowerCase(Locale.ROOT);
                if (!lowerSource.contains(code)) {
                    if (!lowerMemory.contains(code)) problems.add("CODE:" + codes.group());
                    else if (!line.recalled()) problems.add("MEMORY_AS_FACT:" + codes.group());
                }
                codes.appendReplacement(withoutCodes, " ");
            }
            codes.appendTail(withoutCodes);
            Matcher numbers = NUMBER.matcher(withoutCodes);
            while (numbers.find()) {
                String value = normalize(numbers.group());
                if (known.contains(value)) continue;
                if (derivation != null && (derivation.allows(numbers.group(), line.text())
                        || (established.contains(value) && !derivation.statesCurrentData(line.text())))) continue;
                if (!recalled.contains(value)) problems.add("NUMBER:" + numbers.group());
                else if (!line.recalled()) problems.add("MEMORY_AS_FACT:" + numbers.group());
            }
        }
        checkColourLines(text, source, colours == null ? List.of() : colours, problems);
        checkArithmetic(text, problems);
        if (FIRST_PERSON_DONE.matcher(text).find()) problems.add("COMPLETION_CLAIM");
        // A rule explanation describes states ("已提交的单据 ..."); only page and tool answers are checked for bare claims.
        if (derivation == null) {
            Matcher done = DONE_PHRASE.matcher(text);
            while (done.find()) {
                // A status the page or tool itself shows ("已提交") is read off, not claimed.
                String core = done.group(1) != null ? done.group(1) : done.group().strip();
                if (!source.contains(core)) problems.add("COMPLETION_CLAIM:" + core);
            }
        }
        int limit = Math.max(200, maxChars);
        if (text.length() > limit) {
            int cut = text.lastIndexOf('\n', limit - 20);
            text = text.substring(0, cut > limit / 2 ? cut : limit - 20).strip() + "\n...(内容较长，已截断)";
        }
        return new Verdict(problems.isEmpty(), text, List.copyOf(problems));
    }

    /** One line of the reply and whether it says it comes from the earlier conversation. */
    record Line(String text, boolean recalled) {}

    /**
     * Splits the reply into lines. A line is "recalled" when it carries a memory marker itself or, for a list
     * item, when the line introducing the list does; a blank line ends a list.
     */
    static List<Line> lines(String text) {
        List<Line> lines = new ArrayList<>();
        boolean leadRecalled = false;
        for (String line : text.split("\n", -1)) {
            if (line.isBlank()) {
                leadRecalled = false;
                continue;
            }
            boolean item = LIST_ITEM.matcher(line).find();
            boolean recalled = MEMORY_MARKER.matcher(line).find();
            lines.add(new Line(line, recalled || (item && leadRecalled)));
            if (!item) leadRecalled = recalled;
        }
        return lines;
    }

    private static void checkColourLines(String text, String source, List<ColourFact> colours, List<String> problems) {
        // A compact answer may chain several "颜色 = 状态" pairs on one line with "；": each is checked on its own.
        Matcher line = COLOUR_LINE.matcher(text.replaceAll("[；;]\\s*", "\n"));
        while (line.find()) {
            String colour = colourWord(line.group(1));
            String rest = line.group(3);
            String status = line.group(2).replaceAll("[(\uFF08][^)\uFF09]*[)\uFF09]\\s*$", "").strip();
            if (colours.isEmpty()) {
                // No page legend: only the three-part form starting with a colour word is a colour claim; both words
                // must be in the sources. A formula ("短交 = 订货 − 实收 = 5", ADR-153 rule explanations) is not.
                if (rest == null || colour == null) continue;
                String raw = line.group(1).replaceAll("[(\uFF08].*$", "").strip().replaceFirst("色$", "");
                if (!raw.isEmpty() && !source.contains(raw)) problems.add("LEGEND_COLOR:" + raw);
                if (!status.isEmpty() && !source.contains(status)) problems.add("LEGEND_STATUS:" + status);
                continue;
            }
            if (colour == null || status.isEmpty()) continue;
            List<ColourFact> named = colours.stream().filter(fact -> sameStatus(fact.status(), status)).toList();
            if (named.isEmpty()) {
                // Not a legend entry, but the page's own column or field explanation pairs this colour with it
                // ("缺=红, 可领=绿" in a column's info): a page fact as well.
                if (!statedNear(source, colour, status)) problems.add("LEGEND_STATUS:" + status);
                continue;
            }
            List<ColourFact> paired = named.stream().filter(fact -> colour.equals(colourWord(fact.colour()))).toList();
            if (paired.isEmpty()) {
                problems.add("LEGEND_PAIR:" + colour + "=" + status);
                continue;
            }
            Matcher count = COUNT.matcher(line.group(2) + " " + (rest == null ? "" : rest));
            Integer stated = null;
            while (count.find()) stated = Integer.valueOf(count.group(1));
            final Integer claimed = stated;
            if (claimed != null && paired.stream().noneMatch(fact -> fact.count() == null || fact.count().equals(claimed))) {
                problems.add("LEGEND_COUNT:" + colour + "=" + status + "(" + claimed + ")");
            }
        }
    }

    /**
     * One arithmetic step written in the reply: "a op b = c" or "a op b ≈ c", each number with an optional unit. A step
     * that is part of a longer chain ("520 × 300 ÷ 500 = 312") is not taken apart.
     */
    private static final Pattern STEP = Pattern.compile("(?<![\\d.,%×x*÷/+＋\\-−–]\\s?)(?<![\\d.])(\\d+(?:\\.\\d+)?)(%?)\\s*(?:kg|g|克|千克|公斤|个|件|元)?\\s*"
            + "([×x*÷/+＋\\-−–])\\s*(\\d+(?:\\.\\d+)?)(%?)\\s*(?:kg|g|克|千克|公斤|个|件|元)?\\s*([=＝≈])\\s*(\\d+(?:\\.\\d+)?)(?![\\d.]*\\s*[×x*÷/+＋])");

    /**
     * ADR-153 revision: the arithmetic a rule explanation shows must be right. "1 kg + 0.01 kg ≈ 1.02 kg" is rejected; a
     * unit change on the result ("1 kg ÷ 100 = 10 g") is accepted.
     */
    static void checkArithmetic(String text, List<String> problems) {
        Matcher step = STEP.matcher(text);
        while (step.find()) {
            double a = Double.parseDouble(step.group(1)) / (step.group(2).isEmpty() ? 1 : 100);
            double b = Double.parseDouble(step.group(4)) / (step.group(5).isEmpty() ? 1 : 100);
            String result = step.group(7);
            double c = Double.parseDouble(result);
            double value = switch (step.group(3)) {
                case "×", "x", "*" -> a * b;
                case "÷", "/" -> b == 0 ? Double.NaN : a / b;
                case "+", "＋" -> a + b;
                default -> a - b;
            };
            if (Double.isNaN(value)) continue;
            int dot = result.indexOf('.');
            double precision = dot < 0 ? 0.5 : Math.pow(10, -(result.length() - dot - 1)) / 2;
            boolean approximate = "≈".equals(step.group(6));
            boolean right = false;
            for (double scale : new double[] {1, 1000, 0.001, 100, 0.01}) {
                double expected = value * scale;
                // Rounding to the written digits is always fine; "≈" allows a little more (a rounded intermediate step).
                double tolerance = Math.max(precision, Math.abs(expected) * (approximate ? 0.008 : 0.005));
                if (Math.abs(expected - c) <= tolerance) {
                    right = true;
                    break;
                }
            }
            if (!right) problems.add("ARITHMETIC:" + step.group().strip());
        }
    }

    /** The source text itself puts this colour next to this status (within a few characters). */
    static boolean statedNear(String source, String colour, String status) {
        if (source == null || colour == null || status == null || status.length() < 1) return false;
        int from = 0;
        for (int seen = 0; seen < 40; seen++) {
            int at = source.indexOf(status, from);
            if (at < 0) return false;
            String window = source.substring(Math.max(0, at - 12), Math.min(source.length(), at + status.length() + 12));
            if (window.contains(colour)) return true;
            from = at + 1;
        }
        return false;
    }

    private static boolean sameStatus(String fact, String claimed) {
        if (fact == null || fact.isBlank()) return false;
        String a = fact.strip();
        String b = claimed.strip();
        if (a.equals(b)) return true;
        // A shortened status ("部分物料已投" for "部分物料已投 · 可开工") still names that entry.
        return b.length() >= 2 && (a.contains(b) || b.contains(a) && a.length() >= 2);
    }

    /** "绿色" / "浅绿" / "绿色的" -> "绿"; null when the text is not a colour word. */
    static String colourWord(String raw) {
        if (raw == null) return null;
        String word = raw.replaceAll("[(\uFF08].*$", "").replaceAll("\\s+", "").replaceFirst("^(?:浅|深|亮|暗|淡)", "")
                .replaceFirst("(?:底色|色的|色)$", "");
        return COLOUR_WORDS.contains(word) ? word : null;
    }

    /**
     * ADR-153 numbers a rule explanation may compute (narrowed in the A3 review): a new number passes when it is
     * derived from the user's own numbers and a few unit constants in one or two steps ("100 个共 1 kg, 每个约 10 克":
     * 1 / 100 * 1000), or, on a line that shows its arithmetic (÷ × = + -), in one step from the other numbers on
     * that same line and the rule numbers. A line that states current data ("目前/当前/账上/系统里/还剩 ...") only
     * passes numbers derived from the user's own numbers: a plausible-looking stock figure is never made up. Page and
     * tool numbers are never a base: new totals of current business data stay forbidden.
     */
    static final class Derivation {
        private static final double[] CONSTANTS = {1, 2, 10, 100, 1000};
        private static final int MAX_OWN = 12;
        private static final int MAX_RULE = 60;
        /** A line that shows its arithmetic. */
        private static final Pattern ARITHMETIC = Pattern.compile("\\d\\s*(?:[×x*÷/+＋=＝]|[-−–]\\s*\\d)|[=＝≈]\\s*\\d|(?:乘以|除以|加上|减去)");
        /** A line that presents something as the current state of the business data. */
        private static final Pattern CURRENT_STATE = Pattern.compile("目前|当前|现在|现有|眼下|实时|账上|账面上|系统里|系统中|还剩|剩余|结存|在库"
                + "|(?i:\\bcurrently\\b|\\bon\\s+hand\\b|\\bright\\s+now\\b|\\bin\\s+the\\s+system\\b|\\bin\\s+stock\\b)");
        private final double[] own;
        private final List<Double> mine;
        private final List<Double> base;
        private final List<Double> rules;

        private Derivation(double[] own, List<Double> mine, List<Double> base, List<Double> rules) {
            this.own = own;
            this.mine = mine;
            this.base = base;
            this.rules = rules;
        }

        static Derivation of(String question, String ruleText) {
            java.util.LinkedHashSet<Double> mine = new java.util.LinkedHashSet<>();
            for (double value : parse(question)) if (mine.size() < MAX_OWN) mine.add(value);
            java.util.LinkedHashSet<Double> base = new java.util.LinkedHashSet<>(mine);
            for (double constant : CONSTANTS) base.add(constant);
            java.util.LinkedHashSet<Double> rules = new java.util.LinkedHashSet<>();
            for (double value : parse(ruleText)) {
                if (rules.size() >= MAX_RULE) break;
                if (Math.abs(value) < 100_000) rules.add(value);
            }
            List<Double> first = new ArrayList<>();
            for (double a : base) for (double b : base) combine(a, b, first);
            List<Double> all = new ArrayList<>(base);
            all.addAll(first);
            for (double a : first) for (double b : base) combine(a, b, all);
            double[] sorted = all.stream().mapToDouble(Double::doubleValue).filter(Double::isFinite).sorted().distinct().toArray();
            return new Derivation(sorted, List.copyOf(mine), List.copyOf(base), List.copyOf(rules));
        }

        private static void combine(double a, double b, List<Double> out) {
            out.add(a + b);
            out.add(a - b);
            out.add(a * b);
            if (b != 0) out.add(a / b);
        }

        private static List<Double> parse(String text) {
            List<Double> values = new ArrayList<>();
            if (text == null) return values;
            Matcher matcher = NUMBER.matcher(text);
            while (matcher.find()) {
                try { values.add(Double.parseDouble(matcher.group().replace(",", ""))); }
                catch (NumberFormatException ignored) { /* "1.2.3" is not a number */ }
            }
            return values;
        }

        /** Whether {@code raw}, written on {@code line} of the reply, is a number this explanation may compute. */
        boolean allows(String raw, String line) {
            double value;
            try { value = Double.parseDouble(raw.replace(",", "")); }
            catch (NumberFormatException notNumber) { return false; }
            int dot = raw.indexOf('.');
            double unit = dot < 0 ? 1 : Math.pow(10, -(raw.length() - dot - 1));
            double tolerance = Math.max(unit / 2, Math.abs(value) * 0.005);
            if (near(own, value, tolerance) || near(own, value / 100, tolerance / 100)) return true;
            if (line == null || CURRENT_STATE.matcher(line).find() || !ARITHMETIC.matcher(line).find()) return false;
            List<Double> written = parse(line);
            // The arithmetic must start from the user's own example (a number the user gave or one derived from it, not a
            // bare unit constant): a line made only of invented numbers proves nothing.
            boolean fromExample = written.stream().anyMatch(number -> mine.stream().anyMatch(given -> Math.abs(given - number) < 1e-9)
                    || (near(own, number, 1e-9) && java.util.Arrays.stream(CONSTANTS).noneMatch(constant -> constant == number)));
            if (!fromExample) return false;
            List<Double> operands = new ArrayList<>(base);
            for (double number : written) if (Math.abs(number - value) > tolerance) operands.add(number);
            operands.addAll(rules);
            List<Double> step = new ArrayList<>();
            int limit = Math.min(operands.size(), 120);
            for (int i = 0; i < limit; i++) for (int j = 0; j < limit; j++) combine(operands.get(i), operands.get(j), step);
            for (double candidate : step) if (Math.abs(candidate - value) <= tolerance) return true;
            return false;
        }

        /** The line shows its arithmetic (an operator between numbers or an "= number"). */
        boolean showsArithmetic(String line) {
            return line != null && ARITHMETIC.matcher(line).find();
        }

        /** The line presents something as the current state of the business data. */
        boolean statesCurrentData(String line) {
            return line != null && CURRENT_STATE.matcher(line).find();
        }

        /** Kept for callers that check a number without its line (strict: own numbers only). */
        boolean allows(String raw) {
            return allows(raw, null);
        }

        private static boolean near(double[] values, double value, double tolerance) {
            int at = java.util.Arrays.binarySearch(values, value - tolerance);
            int index = at >= 0 ? at : -at - 1;
            return index < values.length && values[index] <= value + tolerance;
        }
    }

    private static Set<String> numbers(String source) {
        Set<String> values = new HashSet<>();
        Matcher matcher = NUMBER.matcher(source);
        while (matcher.find()) {
            values.add(normalize(matcher.group()));
            // "1,234.50" also covers its parts as written in another locale.
            for (String part : matcher.group().split("[.,]")) values.add(normalize(part));
        }
        return values;
    }

    static String normalize(String raw) {
        String value = raw.replace(",", "");
        try {
            BigDecimal number = new BigDecimal(value);
            return number.stripTrailingZeros().toPlainString();
        } catch (NumberFormatException notDecimal) {
            return value.replaceFirst("^0+(?=\\d)", "");
        }
    }
}
