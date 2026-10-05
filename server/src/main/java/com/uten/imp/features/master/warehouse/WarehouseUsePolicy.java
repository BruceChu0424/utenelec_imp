package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseUse;

/**
 * 选仓规则的唯一判定点(ADR-146): 给定一个仓的事实和这次的用途, 说出能不能用、不能用的原因。
 * 纯函数, 不碰数据库; 事实由 {@link WarehouseScopeService} 在锁住祖先链后组装。
 * 数据库兜底(fn_warehouse_is_good_stock_leaf / fn_warehouse_is_defective_leaf 与出入库类别守卫)是同一口径。
 */
public final class WarehouseUsePolicy {

    private WarehouseUsePolicy() {
    }

    /**
     * 一个仓在这次选择时的事实。
     *
     * @param name          仓名(报错用)
     * @param accountable   参与库存记账
     * @param lineSide      车间内料仓
     * @param defective     不良品仓
     * @param parent        下面还有普通子仓(主仓)
     * @param chainComplete 祖先链完整(一直能走到顶层仓)
     * @param chainActive   自身与祖先链全部「使用」
     */
    public record Facts(String name, boolean accountable, boolean lineSide, boolean defective,
                        boolean parent, boolean chainComplete, boolean chainActive) {
    }

    /**
     * 不能用时返回给人看的原因; 能用返回 null。
     *
     * @param facts          null = 仓不存在或已删除
     * @param label          单据上这一格叫什么(如「入库仓库」「调出仓」)
     * @param use            这次的用途
     * @param requireActive  新选的仓: 必须存在、记账、不是车间内料仓、祖先链完整且全部启用;
     *                       编辑时沿用原来的仓(历史身份不变)只核对「不是主仓」与仓库用途
     */
    public static String violation(Facts facts, String label, WarehouseUse use, boolean requireActive) {
        if (facts == null) {
            return requireActive ? label + "不存在、已删除或不参与库存记账, 请重新选择" : null;
        }
        if (requireActive && !facts.accountable()) {
            return label + "不存在、已删除或不参与库存记账, 请重新选择";
        }
        if (requireActive && facts.lineSide()) {
            return label + "必须选择正常仓库, 车间内料仓只能在「车间内料仓」里办理";
        }
        if (facts.parent()) {
            return label + "必须选择具体子仓库, 主仓库「" + facts.name() + "」只用于汇总查询";
        }
        if (requireActive && !facts.chainComplete()) {
            return label + "的所属主仓不完整, 请先修正仓库资料";
        }
        if (requireActive && !facts.chainActive()) {
            return label + "或所属主仓已停用, 请选择其他启用仓库";
        }
        if (facts.defective() && !use.acceptsDefective()) {
            return use == WarehouseUse.GOOD_IN
                    ? label + "「" + facts.name() + "」是不良品仓, 正常货品不能入库, 请选择良品仓; "
                            + "判为不良的货请用「转不良品仓」"
                    : label + "「" + facts.name() + "」是不良品仓, 不能从这里领用或发货, 请选择良品仓";
        }
        if (!facts.defective() && !use.acceptsGood()) {
            return use == WarehouseUse.DEFECTIVE_IN
                    ? label + "「" + facts.name() + "」是良品仓, 转不良品仓只能转入不良品仓"
                    : label + "「" + facts.name() + "」是良品仓, 不良复判转回只能从不良品仓转出";
        }
        return null;
    }
}
