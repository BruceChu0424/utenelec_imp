package com.uten.imp.features.master.goods;

import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;

import java.util.regex.Pattern;

/**
 * 货品英文名称(goods.name_en, ADR-134)的统一口径: 取值规范化、长度校验、来源常量与改名权限。
 *
 * <p>三条写入路径共用这里: 货品资料整单保存(goods:edit)、单独改英文名称
 * ({@code PUT /api/master/goods/{id}/name-en}, goods:name_en:edit 或 goods:edit)、
 * 保存报价/订货单时勾选「设为货品英文名」的学习(同样要求 goods:name_en:edit 或 goods:edit)。
 */
public final class GoodsNameEn {

    /** 人工在货品资料里维护。 */
    public static final String SOURCE_MANUAL = "MANUAL";
    /** 保存报价/订货单时从客户文件学习。 */
    public static final String SOURCE_LEARNED = "LEARNED";

    /** 与 goods.name_en varchar(255) 一致。 */
    public static final int MAX_LENGTH = 255;

    /** 专门维护英文名称的权限码; 持有 goods:edit 的人同样可以改。 */
    public static final String EDIT_AUTHORITY = "goods:name_en:edit";
    public static final String GOODS_EDIT_AUTHORITY = "goods:edit";

    private static final Pattern WHITESPACE = Pattern.compile("(?U)\\s+");
    private static final Pattern ZERO_WIDTH = Pattern.compile("[\u200B\u200C\u200D\uFEFF]");

    private GoodsNameEn() {
    }

    /** 去掉首尾空白、把连续空白合并成一个空格; 空白串归一为 null。不改大小写(保持客户原文)。 */
    public static String normalize(String raw) {
        if (raw == null) return null;
        String collapsed = WHITESPACE.matcher(ZERO_WIDTH.matcher(raw).replaceAll("")).replaceAll(" ").strip();
        return collapsed.isEmpty() ? null : collapsed;
    }

    /** 规范化并校验长度; 超长抛 422(不截断, 截断后的英文名会误导识别)。 */
    public static String normalizeForWrite(String raw) {
        String value = normalize(raw);
        if (value != null && value.codePointCount(0, value.length()) > MAX_LENGTH) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "英文名称不能超过 " + MAX_LENGTH + " 个字符");
        }
        return value;
    }

    /** 比较用的键: NFKC、小写、去标点、合并空白(与识别侧 normalizeDescription 同口径)。 */
    public static String matchKey(String raw) {
        String key = IntakeTextNormalizer.normalizeDescription(raw);
        return key.isEmpty() ? null : key;
    }

    /** 是否可以改英文名称(功能权限; 对象范围由调用方另判)。超级管理员恒可以。 */
    public static boolean canEdit(AuthUser user) {
        if (user == null || user.isVisitor()) return false;
        if (user.isSuperAdmin()) return true;
        var permissions = user.getPermissions();
        return permissions != null
                && (permissions.contains(EDIT_AUTHORITY) || permissions.contains(GOODS_EDIT_AUTHORITY));
    }
}
