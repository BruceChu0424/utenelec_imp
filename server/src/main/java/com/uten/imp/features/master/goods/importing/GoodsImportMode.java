package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Locale;

/**
 * 货品导入模式（2026-10-28）：入口先选模式再选文件，模式贯穿检测与提交，
 * detect 落计划时固化、commit 校验一致后才消费。
 *
 * <ul>
 *   <li>{@link #CREATE_ONLY} 新建货品：不看系统标识（身份上全部按新建处理），
 *       类别沿用文件「类别」列；显式编号占用在用货品仍整行报「编号重复」。</li>
 *   <li>{@link #UPDATE_ONLY} 修改货品：只按系统标识匹配在库货品走差异核对；
 *       无系统标识、未匹配到或指向已删除货品的行一律报错，不允许混入新建/恢复。</li>
 *   <li>{@link #MIXED} 混合导入：既有行为（系统标识在库→修改核对；无/不在库→新建；
 *       指向软删货品→按原 UUID 恢复）。</li>
 * </ul>
 */
public enum GoodsImportMode {
    CREATE_ONLY, UPDATE_ONLY, MIXED;

    /** 导入请求里的宽松解析：缺省=混合；CREATE/UPDATE 简写也认，其余值报校验错。 */
    public static GoodsImportMode parse(String raw) {
        if (raw == null || raw.isBlank()) return MIXED;
        return switch (raw.trim().toUpperCase(Locale.ROOT)) {
            case "CREATE_ONLY", "CREATE" -> CREATE_ONLY;
            case "UPDATE_ONLY", "UPDATE" -> UPDATE_ONLY;
            case "MIXED" -> MIXED;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知的导入模式，请重新选择后重试");
        };
    }
}
