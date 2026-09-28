package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

/**
 * 车间内料仓认料端口 (ADR-131 §3.2、§5.4; ADR-017 跨 feature 只经 Port)。
 *
 * <p>认料是产品级事实: 产品没有期间边时, 车间在开工确认表里选它用内料仓里的哪种料 (MATERIAL),
 * 或选本产品不用内料仓的料、按工单领料 (NONE)。生产执行 (开工确认表)、基础资料 (上线准备、发料方式切换)
 * 都只经本端口读写认料; 实现方在 {@code features.warehouse.materialbin}, 运行在调用方事务里。
 * 数据库守卫负责互斥、料必须是整批领料主料、BOM 接管等不变量, 本端口不另写一套。
 */
public interface WorkshopMaterialChoicePort {

    /** 用内料仓里的某种料 (可多种, 双料件)。 */
    String KIND_MATERIAL = "MATERIAL";
    /** 本产品不用车间内料仓的料, 按工单领料。 */
    String KIND_NONE = "NONE";
    /** 预填来源: 老库货品「材质」文字唯一命中某种料。 */
    String PREFILL_LEGACY_MATERIAL_TEXT = "LEGACY_MATERIAL_TEXT";
    /** 作废原因: 发料方式切换 (基础资料把料改回按工单领料或改分摊方式时)。 */
    String SUPERSEDE_ISSUE_METHOD_SWITCH = "ISSUE_METHOD_SWITCH";

    /** 一种料 (货品 + 颜色; 颜色可空)。 */
    record MaterialRef(UUID goodsId, UUID colorId) {
        public MaterialRef {
            if (goodsId == null) throw new IllegalArgumentException("料不能为空");
        }
    }

    /**
     * 一个产品的认料。
     *
     * @param kind               {@link #KIND_MATERIAL} 或 {@link #KIND_NONE}
     * @param materials          MATERIAL 时至少一种料; NONE 时为空
     * @param alsoOrderMaterials 只对 MATERIAL: 还要按工单领别的料 (例如嵌件), 只允许没有任何 BOM 的产品勾
     * @param prefillSource      用户直接采用预填值时带 {@link #PREFILL_LEGACY_MATERIAL_TEXT}, 否则为空
     */
    record ProductChoice(UUID productGoodsId, String kind, List<MaterialRef> materials,
                         boolean alsoOrderMaterials, String prefillSource) {
        public ProductChoice {
            materials = materials == null ? List.of() : List.copyOf(materials);
        }
    }

    /** 下拉里可选的一种料 (本车间内料仓收的整批领料主料)。 */
    record MaterialOption(UUID goodsId, UUID colorId, String goodsCode, String goodsName, String colorName) {}

    /** 产品 BOM 里某种整批领料的单个重量 (克); 只读展示。 */
    record BomWeight(UUID goodsId, UUID colorId, BigDecimal unitWeightGrams) {}

    /**
     * 开工确认表的一行 (按车间 + 产品聚合所选任务)。
     *
     * @param segmentIds                本次勾选里属于这一行的任务段
     * @param taskCount                 本次任务数
     * @param choiceRequired            是否必须认料 (段状态为待认料); 为假时只是路线未确认, 用料列只读
     * @param prefill                   预填料 (上次认料或老库材质唯一命中); 没有为空
     * @param prefillSource             预填来源, 见 {@link #PREFILL_LEGACY_MATERIAL_TEXT}; 上次认料或没有预填为空
     * @param options                   本车间内料仓收的全部主料 (「不用内料仓的料」选项文案也用它列料名)
     * @param bomWeights                BOM 里已填的单个重量; 为空时界面显示「待补, 不影响开工」
     * @param alsoOrderMaterialsAllowed 能否勾「还要按工单领别的料」(= 产品没有任何 BOM)
     */
    record PendingChoice(UUID workshopDepartmentId, String workshopName,
                         UUID productGoodsId, String productCode, String productName,
                         List<UUID> segmentIds, int taskCount, boolean choiceRequired,
                         List<MaterialRef> prefill, String prefillSource,
                         List<MaterialOption> options, List<BomWeight> bomWeights,
                         boolean alsoOrderMaterialsAllowed) {
        public PendingChoice {
            segmentIds = segmentIds == null ? List.of() : List.copyOf(segmentIds);
            prefill = prefill == null ? List.of() : List.copyOf(prefill);
            options = options == null ? List.of() : List.copyOf(options);
            bomWeights = bomWeights == null ? List.of() : List.copyOf(bomWeights);
        }
    }

    /**
     * 一次写入多个产品的认料 (一个原子请求; 同一产品原有效认料作废为「改认料」后写新行)。
     * 幂等: 同一操作人同一请求号重放不重复写, 同号不同内容拒绝。
     */
    void choose(List<ProductChoice> choices, UUID workshopDepartmentId, String idempotencyKey);

    /** 这些任务段在开工确认表里的行 (按车间 + 产品聚合); 不需要确认的段不出现。 */
    List<PendingChoice> pending(Collection<UUID> segmentIds);

    /**
     * 某种料不再适合认料时 (发料方式或分摊方式切换), 作废所有引用它的有效认料。
     *
     * @param reason 作废原因, 目前只有 {@link #SUPERSEDE_ISSUE_METHOD_SWITCH}
     */
    void supersedeForMaterial(UUID materialGoodsId, String reason);
}
