package com.uten.imp.features.master.learning;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * 从客户文件补全/新建客户时允许写入的客户字段与校验口径(ADR-134)。
 *
 * <p>只开放联系类基础资料(外文名称、全称、联系人、邮箱、电话、手机、地址、税号、网址), 从不涉及
 * 负责人、分类、结账方式、信用等管控字段。取值先规范化(去首尾空白、合并连续空白、去零宽字符),
 * 空白视为「没有」直接忽略; 不合法(超长、邮箱/网址格式不对、未知字段)抛 422, 由保存事务整体回滚,
 * 此时什么都还没写。报错文案只说字段名, 不回显文件里的原值。
 */
public final class ClientDocumentFields {

    /** 字段键(与识别结果 client.enrichment[].field、保存请求 aiIntake.clientFields 的键一致)。 */
    public static final String NAME_EN = "nameEn";
    public static final String FULL_NAME = "fullName";
    public static final String LINKMAN = "linkman";
    public static final String EMAIL = "email";
    public static final String PHONE = "phone";
    public static final String MOBILE = "mobile";
    public static final String ADDRESS = "address";
    public static final String TAX_ID = "taxId";
    public static final String WEBSITE = "website";

    /**
     * 字段定义: 中文名(审计与报错用)、长度上限。顺序即审计摘要里的顺序。邮箱、电话、手机、网址记进
     * 多联系方式表, 上限不超过它的 200 字符。
     */
    public record Field(String key, String label, int maxLength) {
    }

    private static final Map<String, Field> FIELDS;

    static {
        Map<String, Field> fields = new LinkedHashMap<>();
        put(fields, new Field(NAME_EN, "外文名称", 255));
        put(fields, new Field(FULL_NAME, "客户全称", 200));
        put(fields, new Field(LINKMAN, "联系人", 100));
        put(fields, new Field(EMAIL, "邮箱", 200));
        put(fields, new Field(PHONE, "联系电话", 64));
        put(fields, new Field(MOBILE, "手机", 64));
        put(fields, new Field(ADDRESS, "地址", 500));
        put(fields, new Field(TAX_ID, "纳税号", 64));
        put(fields, new Field(WEBSITE, "网址", 200));
        FIELDS = Collections.unmodifiableMap(fields);
    }

    private static final Pattern WHITESPACE = Pattern.compile("(?U)\\s+");
    private static final Pattern ZERO_WIDTH = Pattern.compile("[\\u200B\\u200C\\u200D\\uFEFF]");
    private static final Pattern CONTROL = Pattern.compile("\\p{Cntrl}");
    /** 单个邮箱: 本地部分 + @ + 至少一个点的域名(与常见前端校验同宽松度, 不追求 RFC 全集)。 */
    private static final Pattern EMAIL_PATTERN =
            Pattern.compile("^[A-Za-z0-9._%+\\-']+@[A-Za-z0-9](?:[A-Za-z0-9\\-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9\\-]*[A-Za-z0-9])?)+$");
    /** 电话: 数字、空格、加号、横线、括号、点、斜杠、分机 ext/x; 至少 5 位数字。 */
    private static final Pattern PHONE_PATTERN = Pattern.compile("^[0-9+()\\-./ extEXT#]+$");
    /** 网址: 可带 http(s)://, 主机名至少含一个点, 不允许空白。 */
    private static final Pattern WEBSITE_PATTERN =
            Pattern.compile("^(?:https?://)?[A-Za-z0-9](?:[A-Za-z0-9\\-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9\\-]*[A-Za-z0-9])?)+(?::\\d{1,5})?(?:/\\S*)?$");

    private ClientDocumentFields() {
    }

    private static void put(Map<String, Field> fields, Field field) {
        fields.put(field.key(), field);
    }

    public static Field field(String key) {
        return key == null ? null : FIELDS.get(key);
    }

    /** 去首尾空白、合并连续空白、去零宽与控制字符; 空白返回 null。 */
    public static String clean(String raw) {
        if (raw == null) return null;
        String value = ZERO_WIDTH.matcher(raw).replaceAll("");
        value = CONTROL.matcher(value).replaceAll(" ");
        value = WHITESPACE.matcher(value).replaceAll(" ").strip();
        return value.isEmpty() ? null : value;
    }

    /**
     * 规范化并校验一组要写入客户资料的字段。未知键、超长、格式不对抛 422; 空白值被忽略。
     *
     * @return 键 → 规范化后的值(只含非空白), 按字段定义顺序
     */
    public static Map<String, String> normalizeAndValidate(Map<String, String> raw) {
        Map<String, String> out = new LinkedHashMap<>();
        if (raw == null || raw.isEmpty()) return out;
        for (String key : raw.keySet()) {
            if (field(key) == null) {
                throw invalid("文件里的客户信息包含系统不认识的字段, 请重新识别后再保存");
            }
        }
        for (Field field : FIELDS.values()) {
            if (!raw.containsKey(field.key())) continue;
            String value = normalizeValue(field, raw.get(field.key()));
            if (value != null) out.put(field.key(), value);
        }
        return out;
    }

    /** 单个字段规范化 + 校验; 空白返回 null。 */
    public static String normalizeValue(Field field, String raw) {
        String value = clean(raw);
        if (value == null) return null;
        if (value.codePointCount(0, value.length()) > field.maxLength()) {
            throw invalid("客户" + field.label() + "太长(最多 " + field.maxLength() + " 个字符), 请取消勾选或改短后再保存");
        }
        switch (field.key()) {
            case EMAIL -> {
                value = value.replace(" ", "");
                if (!EMAIL_PATTERN.matcher(value).matches()) {
                    throw invalid("客户邮箱格式不对, 请取消勾选或改正后再保存");
                }
            }
            case PHONE, MOBILE -> {
                long digits = value.chars().filter(Character::isDigit).count();
                if (!PHONE_PATTERN.matcher(value).matches() || digits < 5) {
                    throw invalid("客户" + field.label() + "格式不对, 请取消勾选或改正后再保存");
                }
            }
            case WEBSITE -> {
                if (!WEBSITE_PATTERN.matcher(value).matches()) {
                    throw invalid("客户网址格式不对, 请取消勾选或改正后再保存");
                }
            }
            default -> {
                // 其余为自由文本, 只限长度。
            }
        }
        return value;
    }

    /** 审计摘要用的字段中文名列表(只列名字, 不含值)。 */
    public static String labels(Iterable<String> keys) {
        StringBuilder out = new StringBuilder();
        for (String key : keys) {
            Field field = field(key);
            if (field == null) continue;
            if (!out.isEmpty()) out.append(", ");
            out.append(field.label());
        }
        return out.toString();
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
