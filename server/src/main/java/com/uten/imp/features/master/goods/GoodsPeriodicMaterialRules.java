package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.unit.Unit;
import org.postgresql.util.PSQLException;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * 整批领料的料在基础资料里的共用口径 (ADR-131 §3.1、§3.2、§5.1)。
 *
 * <p>期间边 = 组件发料方式为整批领料的 BOM 行, 只填单个重量: 形状固定为开工前、按每件、基准产量 1、
 * 不设齐套门槛 (数据库 {@code fn_guard_periodic_bom_edge} 兜底)。界面按克输入, 库里存组件基本单位
 * (千克时 /1000, 5 位小数 = 0.01 克); 只有名称为千克/公斤/kg 或克/g 的单位能按克换算, 其它质量单位按原单位填。
 * 单个重量小于 0.1 克或大于 5000 克要人确认; 与货品资料单重相差 20% 以上只提醒。
 */
public final class GoodsPeriodicMaterialRules {

    public static final String ORDER = "ORDER";
    public static final String PERIODIC = "PERIODIC";
    public static final String OWN = "OWN";
    public static final String SHARED = "SHARED";
    public static final String EXPENSE = "EXPENSE";
    public static final Set<String> COST_BASES = Set.of(OWN, SHARED, EXPENSE);

    /** 请求里确认异常单重的字段名 (422 的 fieldErrors 用它告诉界面要弹确认)。 */
    public static final String CONFIRM_UNUSUAL_WEIGHT = "confirmUnusualWeight";
    /** 请求里确认同一产品第二种整批领料的料的字段名。 */
    public static final String CONFIRM_SECOND_MATERIAL = "confirmSecondPeriodicMaterial";

    public static final String SHARED_NOT_IN_BOM = "色母这类辅料不写进 BOM, 按当期主料用量分到各产品";
    public static final String SHAPE_ONLY_UNIT_WEIGHT = "整批领料的料在 BOM 里只填单个重量, 不能设成按包装或固定批耗";

    private static final BigDecimal THOUSAND = BigDecimal.valueOf(1000);
    private static final BigDecimal MIN_USUAL_GRAMS = new BigDecimal("0.1");
    private static final BigDecimal MAX_USUAL_GRAMS = BigDecimal.valueOf(5000);
    private static final BigDecimal WARN_RATIO = new BigDecimal("0.2");
    /** 与内料仓 (认料单重展示) 同一组千克别名。 */
    private static final Set<String> KILOGRAM_NAMES = Set.of("千克", "公斤", "kg", "kgs");
    private static final Set<String> GRAM_NAMES = Set.of("克", "g", "公克");
    /** BOM 用量列的小数位 (goods_bom_items.qty NUMERIC(18,5))。 */
    public static final int QTY_SCALE = 5;

    private GoodsPeriodicMaterialRules() {}

    public static boolean isPeriodic(Goods goods) {
        return goods != null && PERIODIC.equals(goods.getIssueMethod());
    }

    /** 辅料或记车间费用: 不写进 BOM。 */
    public static boolean isSharedBasis(String costBasis) {
        return SHARED.equals(costBasis) || EXPENSE.equals(costBasis);
    }

    /** 1 个基本单位是多少克; 不能按克换算的单位返回 null。 */
    public static BigDecimal gramsPerUnit(String unitName) {
        if (unitName == null) return null;
        String name = unitName.strip().toLowerCase(Locale.ROOT);
        if (KILOGRAM_NAMES.contains(name)) return THOUSAND;
        if (GRAM_NAMES.contains(name)) return BigDecimal.ONE;
        return null;
    }

    public static BigDecimal gramsPerUnit(Unit unit) {
        return unit == null || unit.isDeleted() ? null : gramsPerUnit(unit.getName());
    }

    /** 基本单位用量换成克; 单位不能换算时为 null。 */
    public static BigDecimal toGrams(BigDecimal qty, BigDecimal gramsPerUnit) {
        if (qty == null || gramsPerUnit == null) return null;
        return qty.multiply(gramsPerUnit).stripTrailingZeros();
    }

    /** 克换回基本单位用量 (5 位小数)。 */
    public static BigDecimal fromGrams(BigDecimal grams, BigDecimal gramsPerUnit) {
        return grams.divide(gramsPerUnit, QTY_SCALE, RoundingMode.HALF_UP);
    }

    public static boolean unusual(BigDecimal grams) {
        return grams != null && (grams.compareTo(MIN_USUAL_GRAMS) < 0 || grams.compareTo(MAX_USUAL_GRAMS) > 0);
    }

    public static String gramsText(BigDecimal grams) {
        return grams == null ? "" : grams.stripTrailingZeros().toPlainString();
    }

    public static String unusualWeightMessage(String materialLabel, BigDecimal grams) {
        return "「" + materialLabel + "」的单个重量 " + gramsText(grams) + " 克看起来不太对, 确认无误后再保存";
    }

    public static String secondMaterialMessage(String productLabel) {
        return "「" + productLabel + "」要同时用两种料吗 (双色 / 双料)? 如果只是换料, 请改原来那一行";
    }

    /** 需要人确认才能保存 (422, fieldErrors 带确认字段名, 界面据此弹确认框后带上确认再提交)。 */
    public static ApiException confirmationRequired(List<ApiError.FieldError> confirmations) {
        String message = confirmations.size() == 1
                ? confirmations.getFirst().message()
                : "有 " + confirmations.size() + " 处需要确认, 确认无误后再保存";
        return new ApiException(ErrorCode.VALIDATION_FAILED, message, confirmations);
    }

    /** 这个拒绝只是"要人确认" (fieldErrors 全是确认字段), 确认后原样重发即可。 */
    public static boolean isConfirmation(ApiException error) {
        List<ApiError.FieldError> fields = error.getFieldErrors();
        return error.getCode() == ErrorCode.VALIDATION_FAILED && fields != null && !fields.isEmpty()
                && fields.stream().allMatch(field -> CONFIRM_UNUSUAL_WEIGHT.equals(field.field())
                        || CONFIRM_SECOND_MATERIAL.equals(field.field()));
    }

    /**
     * 产品货品资料单重 (m_weight 按单重单位换成克); 单重单位不能按克换算或没填时为 null。
     */
    public static BigDecimal goodsWeightGrams(Goods product) {
        if (product == null || product.getMWeight() == null || product.getMWeight().signum() <= 0) return null;
        return toGrams(product.getMWeight(), gramsPerUnit(product.getMWeightUnit()));
    }

    /** 单个重量与货品资料单重相差 20% 以上时的提醒; 不拦保存。 */
    public static String differenceWarning(String productLabel, BigDecimal edgeGrams, BigDecimal goodsGrams) {
        if (edgeGrams == null || goodsGrams == null || goodsGrams.signum() <= 0) return null;
        BigDecimal ratio = edgeGrams.subtract(goodsGrams).abs().divide(goodsGrams, 4, RoundingMode.HALF_UP);
        if (ratio.compareTo(WARN_RATIO) <= 0) return null;
        return "「" + productLabel + "」的单个重量 " + gramsText(edgeGrams) + " 克与货品资料单重 "
                + gramsText(goodsGrams) + " 克相差 " + ratio.movePointRight(2).setScale(0, RoundingMode.HALF_UP)
                .toPlainString() + "%, 请核对";
    }

    public static String label(Goods goods) {
        if (goods == null) return "这个货品";
        String code = goods.getCode() == null ? "" : goods.getCode().strip();
        String name = goods.getName() == null ? "" : goods.getName().strip();
        String text = (code + " " + name).strip();
        return text.isEmpty() ? "这个货品" : text;
    }

    /**
     * 把 V740 数据库守卫 (23514) 的拒绝原因原样交给员工 (V740 的守卫文案都是写给员工看的中文)。
     * 只认 V740 自己的约束名, 其它约束照旧交给全局异常处理。
     */
    public static RuntimeException translate(RuntimeException error) {
        if (error instanceof ApiException) return error;
        int depth = 0;
        for (Throwable cause = error; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (cause instanceof PSQLException postgres && "23514".equals(postgres.getSQLState())
                    && postgres.getServerErrorMessage() != null) {
                String constraint = postgres.getServerErrorMessage().getConstraint();
                String message = postgres.getServerErrorMessage().getMessage();
                if (constraint != null && message != null && ownConstraint(constraint)) {
                    return new ApiException(ErrorCode.CONFLICT, message);
                }
            }
        }
        return error;
    }

    private static boolean ownConstraint(String constraint) {
        return constraint.startsWith("goods_issue_method")
                || constraint.startsWith("goods_periodic")
                || constraint.startsWith("periodic_")
                || constraint.startsWith("workshop_material");
    }
}
