package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.DataScopeDefinitionDto;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.List;

/** Authoritative plain-language catalog for the global data-visibility page. */
@Service
public class DataScopeCatalogService {

    @Value("${uten.features.goods-owner-scope-enabled:false}")
    private boolean goodsOwnerScopeEnabled;

    public List<DataScopeDefinitionDto> list() {
        return List.of(
                definition(
                        "client", "客户资料(内销、外贸、OEM统一)",
                        "额外查看所选负责人名下的全部客户；不改变负责人，默认只读。",
                        "client:view:all", true, null, "客户与销售"),
                definition(
                        "sales", "销售单据",
                        "额外查看所选负责人名下的历史和在途销售单据；不改变当前责任。",
                        "sales:view:all", true, null, "客户与销售"),
                definition(
                        "goods", "货品资料",
                        goodsOwnerScopeEnabled
                                ? "额外查看所选负责人名下的货品资料。"
                                : "当前系统配置为货品资料全员可见，此设置暂不产生过滤效果。",
                        "goods:view:all", goodsOwnerScopeEnabled,
                        goodsOwnerScopeEnabled ? null : "货品归属过滤当前未启用",
                        "客户与销售"),
                definition(
                        "purchase", "采购单据",
                        "额外查看所选负责人名下的采购单据；只读查看不等于责任交接。",
                        "purchase:view:all", true, null, "采购与委外"),
                definition(
                        "subcontract", "委外单据",
                        "额外查看所选负责人名下的委外单据；只读查看不等于责任交接。",
                        "subcontract:view:all", true, null, "采购与委外"),
                definition(
                        "production_plan", "生产计划与日报",
                        "额外查看所选负责人名下的生产计划和日报。",
                        "production_plan:view:all", true, null, "生产与仓库"),
                definition(
                        "stock_doc", "仓库单据",
                        "额外查看所选负责人名下的仓库单据。",
                        "stock_doc:view:all", true, null, "生产与仓库"),
                definition(
                        "finance", "财务单据",
                        "额外查看所选负责人名下的收付款、费用和转账单据。",
                        "finance:view:all", true, null, "财务")
        );
    }

    private static DataScopeDefinitionDto definition(
            String scope,
            String label,
            String description,
            String viewAllPermission,
            boolean enabled,
            String disabledReason,
            String group) {
        return new DataScopeDefinitionDto(
                scope, label, description, viewAllPermission,
                enabled, disabledReason, group);
    }
}
