package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货架目视化清单行（仓库管理 → 货架目视化清单 / 货架图 + 统一表格 / 打印张贴 / 导出）。
 *
 * <p>对标仓库现场「目视化管理清单 Visual Management List」挂牌：库位号按「库行-层-位」
 * 三段解析（{@link com.uten.imp.features.stock.ShelfPlaceParser}），前端据此画货架图；
 * 不符合三段格式的库位号 {@code parsed=false}，归「未分层」桶。
 *
 * <p>数据来源：货品主档 goods.stock_place（库位号）；选仓查询时本仓偏好
 * （warehouse_goods_place_preferences）优先。即时库存 {@code qty} 仅作参考列
 * （未选仓=全部核算仓汇总；选仓=该仓及子仓汇总），货架摆放以库位号为准。
 */
@Getter
@AllArgsConstructor
public class ShelfLabelRow {
    private UUID goodsId;
    /** 库行（货架编号，如 A31；未分层时为空串）。 */
    private String rack;
    /** 库位号（选仓时 = 本仓偏好优先，否则主档原值；已 BTRIM）。 */
    private String place;
    /** 物料编码（goods.code）。 */
    private String goodsCode;
    /** 物料系列（goods.series）。 */
    private String series;
    /** 物料名称（goods.name）。 */
    private String goodsName;
    /** 颜色（goods.color_id → colors.name；主档未填色时为空串）。 */
    private String colorName;
    /** 单位名称（goods.unit_id / unit_legacy_id → units.name；无则空串）。 */
    private String unitName;
    /** 即时库存（参考列，见类注释口径；无余额行为 0）。 */
    private BigDecimal qty;
    /** 货品已禁用（goods.status='禁用'）；默认查询不含禁用货品，includeDisabled=true 时才出现。 */
    private boolean disabled;
    /** 层（三段解析第二段；未分层为 null）。 */
    private Integer level;
    /** 位（三段解析第三段；未分层为 null）。 */
    private Integer slot;
    /** 库位号是否符合「库行-层-位」三段格式。 */
    private boolean parsed;
}
