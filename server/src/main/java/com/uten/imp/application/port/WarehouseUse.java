package com.uten.imp.application.port;

/**
 * 选仓用途(ADR-146): 一张单据上的这个仓要拿来做什么。服务端选仓校验只认它
 * ({@code WarehouseScopeService.require}), 判定规则只有一份({@code WarehouseUsePolicy})。
 *
 * <p>仓库分两类: 良品仓 / 不良品仓(warehouses.is_defective)。不良品仓平时不能当普通仓用,
 * 只经「转不良品仓」「不良复判转回」两条专门通道和盘点、报废、退货进出。
 */
public enum WarehouseUse {
    /** 良品入库: 采购/IQC 上架/委外回厂/产成品登记与点收/报工入仓/其它入库/余料良品退库/
     *  委外材料退回/退货良品释放与退货表头仓/货品所属仓库。只能是良品仓。 */
    GOOD_IN,
    /** 良品出库: 生产领料/内料仓发料来源/委外发料/销售与客户发货/产成品出仓。只能是良品仓。 */
    GOOD_OUT,
    /** 转入不良品仓: 「转不良品仓」的调入仓。只能是不良品仓。 */
    DEFECTIVE_IN,
    /** 从不良品仓转出: 「不良复判转回」的调出仓。只能是不良品仓。 */
    DEFECTIVE_OUT,
    /** 处置出库: 报废/其它出库/采购退货/委外成品退回。良品仓、不良品仓都可以。 */
    DISPOSAL_OUT,
    /** 普通调拨的两端: 良品仓、不良品仓都可以, 但两端必须同类(调用方另行比较)。 */
    TRANSFER,
    /** 盘点与授权余额调整: 良品仓、不良品仓都可以。 */
    COUNT;

    /** 这个用途能不能落在不良品仓。 */
    public boolean acceptsDefective() {
        return this != GOOD_IN && this != GOOD_OUT;
    }

    /** 这个用途能不能落在良品仓。 */
    public boolean acceptsGood() {
        return this != DEFECTIVE_IN && this != DEFECTIVE_OUT;
    }
}
