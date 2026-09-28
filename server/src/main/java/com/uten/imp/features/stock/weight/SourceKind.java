package com.uten.imp.features.stock.weight;

import java.util.Locale;

/**
 * 称重观测的来源种类 (ADR-135 §4/§5)。
 *
 * <p>角色决定它能不能教单重:
 * <ul>
 *   <li>REFERENCE: 数量是独立点数/登记来的 (称样、盘点、到货、产成品登记、其它入库), 参与学习;</li>
 *   <li>CHECK: 出库执行核对 (领料、委外发料、销售出库、退料、其它出库、调拨), 数量是计划/应发数,
 *       称重往往就是按单重称出来的, 只用于偏差提示; 估算器只额外读 DRAW 算「领料实发比应发」。</li>
 * </ul>
 * eps 是该来源数量本身的相对误差 (数错/登记误差), 进入单条观测方差 V = γ²/max(q,1) + eps² + (r/w)²/3;
 * 个别观测可用 qty_eps 覆盖 (如产成品有仓库点数 0.005, 只有报工数 0.015)。
 */
public enum SourceKind {
    SAMPLE(Role.REFERENCE, 0.0),
    COUNT(Role.REFERENCE, 0.005),
    RECEIPT(Role.REFERENCE, 0.010),
    FINISHED(Role.REFERENCE, 0.010),
    OTHER_IN(Role.REFERENCE, 0.020),
    DRAW(Role.CHECK, 0.010),
    ISSUE(Role.CHECK, 0.010),
    SHIPMENT(Role.CHECK, 0.010),
    RETURN(Role.CHECK, 0.020),
    OTHER_OUT(Role.CHECK, 0.010),
    TRANSFER(Role.CHECK, 0.010);

    /** 观测角色, 与 goods_weight_observations.role 的取值一致。 */
    public enum Role { REFERENCE, CHECK }

    private final Role role;
    private final double eps;

    SourceKind(Role role, double eps) {
        this.role = role;
        this.eps = eps;
    }

    public Role role() {
        return role;
    }

    /** 该来源数量的默认相对误差。 */
    public double eps() {
        return eps;
    }

    public boolean isReference() {
        return role == Role.REFERENCE;
    }

    /** 按库内代码解析 (不区分大小写); 不认识时抛 IllegalArgumentException。 */
    public static SourceKind parse(String code) {
        if (code == null || code.isBlank()) {
            throw new IllegalArgumentException("source kind is blank");
        }
        return valueOf(code.strip().toUpperCase(Locale.ROOT));
    }
}
