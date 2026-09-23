package com.uten.imp.features.master.lifecycle;

import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;

/**
 * 主档命令的对象级写权限(ADR-111)：与各主档单条编辑用的是同一套判定。
 *
 * <p>客户按负责人范围(ClientAccessPolicy)；货品按归属人范围(总开关
 * uten.features.goods-owner-scope-enabled 关闭时全员可写)；其余主档没有对象级范围。
 * 每个命令只评估一次范围，再对锁定行逐条套用，不做逐行查询。
 */
@Component
@RequiredArgsConstructor
public class MasterObjectAccess {

    private final OwnerVisibility ownerVisibility;
    private final ClientAccessPolicy clientAccessPolicy;

    @Value("${uten.features.goods-owner-scope-enabled:false}")
    private boolean goodsOwnerScopeEnabled;

    /** 返回「负责人 id → 当前用户能否写」判定；负责人列不存在的主档恒为可写。 */
    Predicate<UUID> writableOwner(MasterEntityKind kind) {
        return switch (kind) {
            case CLIENT -> {
                ClientAccessPolicy.ClientScope scope = clientAccessPolicy.evaluate();
                yield owner -> clientAccessPolicy.canWriteOwner(owner, scope);
            }
            case GOODS -> {
                if (!goodsOwnerScopeEnabled) yield owner -> true;
                OwnerVisibility.OwnerScope scope = ownerVisibility.evaluate("goods", "goods:view:all");
                yield owner -> scope.seeAll() || owner == null || scope.writableOwners().contains(owner);
            }
            default -> owner -> true;
        };
    }

    /**
     * 货品读可见性(组装信息粘贴等批量校验用)：口径同 MasterReferenceValidationAdapter.canViewGoods，
     * 只是按负责人列一次判定，不逐个货品查库。
     */
    public Predicate<UUID> visibleGoodsOwner() {
        if (!goodsOwnerScopeEnabled) return owner -> true;
        OwnerVisibility.OwnerScope scope = ownerVisibility.evaluate("goods", "goods:view:all");
        return owner -> scope.seeAll() || owner == null || scope.visibleOwners().contains(owner);
    }

    /**
     * 引用检查拒绝原因里的样例标签能不能给当前用户看(ADR-111)：{@code public} 恒可见；
     * {@code goods} 按货品归属人；其余是单据模块的归属范围名，口径同各模块 DocumentAccessPolicy
     * (超管或 {@code 范围:view:all} 全见，无归属人的老数据可见，否则按本人/交接/数据范围授权)。
     * 看不到的只计数不展示，删除照样被拒——既不泄露单号/货品名，也不放过引用。
     */
    public Predicate<UUID> readableLabelOwner(String scope) {
        if ("public".equals(scope)) return owner -> true;
        if ("goods".equals(scope)) return visibleGoodsOwner();
        if (!DOCUMENT_SCOPES.contains(scope)) {
            // 目录里写错了范围名：宁可只计数不展示(删除照样被拒)，也不把标签漏给看不到的人。
            return owner -> false;
        }
        OwnerVisibility.OwnerScope granted = ownerVisibility.evaluate(scope, scope + ":view:all");
        return owner -> granted.seeAll() || owner == null || granted.visibleOwners().contains(owner);
    }

    /** 引用目录里用到的单据归属范围名(与 user_data_scopes.scope、各模块 *:view:all 一致)。 */
    static final Set<String> DOCUMENT_SCOPES = Set.of(
            "sales", "purchase", "subcontract", "stock_doc", "production_plan", "finance");

    /** 该主档是否按负责人列做对象级授权(决定锁定查询要不要取 owner_employee_id)。 */
    static boolean ownerScoped(MasterEntityKind kind) {
        return kind == MasterEntityKind.CLIENT || kind == MasterEntityKind.GOODS;
    }
}
