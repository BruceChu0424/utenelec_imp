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
 * <p>每行保留真实仓库×货品×颜色。库位来自精确主档关系或货品一般建议；
 * {@code qty} 是该仓货色库存参考量，不是该库位的实物盘点数。
 * 无实际维度的主档建议行仓库为空、数量为0。
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
    /** 颜色(实际行 color_id → colors.name；NULL色为空串，不继承货品主颜色)。 */
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
    /** Actual warehouse; null means a master-only suggestion with zero quantity. */
    private UUID warehouseId;
    private String warehouseName;
    /** Exact stock/relation color; NULL is not replaced by the goods primary color. */
    private UUID colorId;
    private String placeSource;
}
