package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * ADR-152 how one answer is presented: the account's default detail level, overridden for this turn only
 * when the user's own words ask for it ("简单点" / "详细点" / "展开说"), plus an optional format the words
 * ask for (an example or numbered steps). The model never picks a shorter length by itself.
 *
 * @param detail     effective detail level for this turn
 * @param format     {@code EXAMPLE}, {@code STEPS} or empty
 * @param overridden the detail level comes from the question rather than the setting
 */
record AiChatPresentation(AiChatSettings.Detail detail, String format, boolean overridden) {
    private static final Pattern BRIEF = Pattern.compile(
            ".*(?:简短|简洁|简单(?:说|点|一点|一些|些)|简要|精简|说重点|一句话|概括|总结一下|"
                    + "(?:不要|不用|不需要|无需|不必|别).{0,8}(?:展开|详细|明细)|summar|brief|simpler|keepitshort|간단).*");
    private static final Pattern DETAILED = Pattern.compile(
            ".*(?:详细|展开|全面|完整|具体说|具体点|全部列出|全都列出|列全|明细|每一条|indetail|details|"
                    + "showall|elaborate|자세히).*");
    private static final Pattern EXAMPLE = Pattern.compile(".*(?:举例|举个例|例子|示例|example|예를).*");
    private static final Pattern STEPS = Pattern.compile(".*(?:步骤|一步一步|分步|按步|下一步怎么|stepbystep|steps|단계).*");

    static AiChatPresentation resolve(AiChatSettings.Detail setting, String message) {
        String value = normalized(message);
        AiChatSettings.Detail detail = setting == null ? AiChatSettings.Detail.STANDARD : setting;
        boolean overridden = false;
        if (BRIEF.matcher(value).matches()) {
            overridden = detail != AiChatSettings.Detail.CONCISE;
            detail = AiChatSettings.Detail.CONCISE;
        } else if (DETAILED.matcher(value).matches()) {
            overridden = detail != AiChatSettings.Detail.COMPREHENSIVE;
            detail = AiChatSettings.Detail.COMPREHENSIVE;
        }
        String format = EXAMPLE.matcher(value).matches() ? "EXAMPLE" : STEPS.matcher(value).matches() ? "STEPS" : "";
        return new AiChatPresentation(detail, format, overridden);
    }

    /** Mode name of the deterministic renderers (page guide, knowledge entries). */
    String renderMode() {
        if (!format.isEmpty()) return format;
        return detail == AiChatSettings.Detail.CONCISE ? "SUMMARY" : "OVERVIEW";
    }

    /** A tool's detailed reply is used when the answer should be comprehensive. */
    boolean wantsDetails() {
        return detail == AiChatSettings.Detail.COMPREHENSIVE;
    }

    /** Longest reply the answer guard keeps for this level. */
    int maxReplyChars() {
        return detail == AiChatSettings.Detail.COMPREHENSIVE ? 6000 : AiChatAnswerGuard.MAX_REPLY;
    }

    /** The length and shape instruction given to the model. */
    String instruction() {
        String length = switch (detail) {
            case CONCISE -> "Length: CONCISE. Answer in one or two sentences with the conclusion only. When the user "
                    + "asks for a list (colours, items to check, rows), give one short line per item with no explanation "
                    + "(at most 6, then \"还有 N 项\"); no examples or next steps. ";
            case STANDARD -> "Length: STANDARD. Start with the direct answer, then the key supporting points as a numbered "
                    + "list; cover every item the user asked about (at most 12, then \"还有 N 项\"); add a next step only "
                    + "when it is obvious. ";
            case COMPREHENSIVE -> "Length: COMPREHENSIVE. Start with the direct answer, then give every relevant item with "
                    + "its basis (which row, column or source), a short example where it helps (label it 举例(假设), never "
                    + "presented as current data) and the concrete next steps (at most 30 items, then \"还有 N 项\"). ";
        };
        if (overridden) length += "The user asked for this length in the current question; it overrides their default. ";
        return length + switch (format) {
            case "EXAMPLE" -> "Include a clearly hypothetical example labelled 举例(假设), never presented as current data. ";
            case "STEPS" -> "Give numbered steps in order. ";
            default -> "";
        };
    }

    private static String normalized(String value) {
        if (value == null || value.length() > 2000) return "";
        return Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT).replaceAll("[\\s\\p{P}]+", "");
    }
}
