package com.uten.imp.features.master.platformcolumns;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.account.Account;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryService;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.currency.Currency;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.mould.Mould;
import com.uten.imp.features.master.mould.MouldService;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryService;
import com.uten.imp.features.master.paymentstyle.PaymentStyle;
import com.uten.imp.features.master.paymentstyle.PaymentStyleService;
import com.uten.imp.features.master.referencemethod.SettlementMethod;
import com.uten.imp.features.master.referencemethod.SettlementMethodRepository;
import com.uten.imp.features.master.supplier.Supplier;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryService;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.warehouse.Warehouse;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.function.Predicate;

@Configuration
@RequiredArgsConstructor
public class MasterPlatformColumnAdapters {
    private final SecurityContextCurrentUser current;
    private final EntityManager em;
    private final ObjectMapper json;
    private final SystemMasterCategoryRegistry systemCategories;

    @Bean PlatformColumnResourceAdapter masterGoodsColumns(GoodsService service) {
        return adapter("goods", "货品资料", Set.of("goods:price:view", "goods:price:edit"), Goods.class, service::detail,
                row -> row.path("writable").asBoolean(false), List.of(
                        fact("price", "售价", true), fact("stockQty", "当前库存数量", false),
                        fact("mWeight", "单重", false), fact("thickness", "厚度", false),
                        fact("minOrderQty", "最小起订量", false), fact("orderMultipleQty", "订货倍数", false)));
    }
    @Bean PlatformColumnResourceAdapter masterClientColumns(ClientService service) {
        return adapter("client", "客户资料", Set.of("client:view"), Client.class, service::detail,
                row -> row.path("writable").asBoolean(false), List.of(fact("tday", "结算天数", false)));
    }
    @Bean PlatformColumnResourceAdapter masterSupplierColumns(SupplierService service) {
        return simple("supplier", "供应商资料", Supplier.class, service::detail);
    }
    @Bean PlatformColumnResourceAdapter masterMouldColumns(MouldService service) {
        return adapter("mould", "模具资料", Set.of("mould:view"), Mould.class, service::detail, row -> true,
                List.of(fact("tqty", "总数量", false)));
    }
    @Bean PlatformColumnResourceAdapter masterColorColumns(ColorService service) {
        return simple("color", "颜色资料", Color.class, service::detail);
    }
    @Bean PlatformColumnResourceAdapter masterUnitColumns(UnitService service) {
        return simple("unit", "单位资料", Unit.class, service::detail);
    }
    @Bean PlatformColumnResourceAdapter masterCurrencyColumns(CurrencyService service) {
        return adapter("currency", "币种资料", Set.of("currency:view"), Currency.class, service::detail, row -> true,
                List.of(fact("exchangeRate", "汇率", false)));
    }
    @Bean PlatformColumnResourceAdapter masterWarehouseColumns(WarehouseService service) {
        return simple("warehouse", "仓库资料", Warehouse.class, service::detail);
    }
    @Bean PlatformColumnResourceAdapter masterAccountColumns(AccountService service) {
        return adapter("account", "账户资料", Set.of("account:balance:view"), Account.class, service::detail,
                row -> !row.path("autoCreated").asBoolean(false), List.of(
                        fact("balanceCurrent", "当前余额", true), fact("balanceFloor", "余额预警线", true),
                        fact("receiptsTotal", "累计收款", true), fact("paymentsTotal", "累计付款", true)));
    }
    @Bean PlatformColumnResourceAdapter masterPaymentStyleColumns(PaymentStyleService service) {
        return simple("payment_style", "收支科目", PaymentStyle.class, service::detail);
    }
    @Bean PlatformColumnResourceAdapter masterSettlementColumns(SettlementMethodRepository repository) {
        // This dictionary has no detail endpoint; use its existing repository and the updateTerms system-role guard.
        return adapter("settlement_method", "结算方式", Set.of("settlement_method:view"), SettlementMethod.class, id -> {
            SettlementMethod row = repository.findById(id).filter(value -> !value.isDeleted())
                    .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "结算方式不存在"));
            return Map.of("id", row.getId(), "writable", row.getSystemRole() == null || row.getSystemRole().isBlank(),
                    "defaultDueDays", row.getDefaultDueDays());
        }, row -> row.path("writable").asBoolean(false), List.of(fact("defaultDueDays", "默认账期天数", false)));
    }
    @Bean PlatformColumnResourceAdapter masterMaterialCategoryColumns(MaterialCategoryService service) {
        return adapter("material_category", "货品分类", Set.of("material_category:view"), MaterialCategory.class, service::detail,
                row -> !systemCategories.isMaterialCategory(id(row)), List.of());
    }
    @Bean PlatformColumnResourceAdapter masterClientCategoryColumns(ClientCategoryService service) {
        return adapter("client_category", "客户分类", Set.of("client_category:view"), ClientCategory.class, service::detail,
                row -> !systemCategories.isClientCategory(id(row)), List.of());
    }
    @Bean PlatformColumnResourceAdapter masterSupplierCategoryColumns(SupplierCategoryService service) {
        return adapter("supplier_category", "供应商分类", Set.of("supplier_category:view"), SupplierCategory.class, service::detail,
                row -> !systemCategories.isSupplierCategory(id(row)), List.of());
    }
    @Bean PlatformColumnResourceAdapter masterMouldCategoryColumns(MouldCategoryService service) {
        return adapter("mould_category", "模具分类", Set.of("mould_category:view"), MouldCategory.class, service::detail,
                row -> !systemCategories.isMouldCategory(id(row)), List.of());
    }
    private MasterPlatformColumnAdapter simple(String permission, String label, Class<?> type, Function<UUID, ?> detail) {
        return adapter(permission, label, Set.of(permission + ":view"), type, detail, row -> true, List.of());
    }
    private MasterPlatformColumnAdapter adapter(String permission, String label, Set<String> priceReaders, Class<?> type,
            Function<UUID, ?> detail, Predicate<JsonNode> writable, List<FactDefinition> facts) {
        return new MasterPlatformColumnAdapter("master_" + permission, label, permission, priceReaders, type,
                detail, writable, facts, current, em, json);
    }
    private static FactDefinition fact(String key, String name, boolean money) { return new FactDefinition(key, name, money); }
    private static UUID id(JsonNode row) { return UUID.fromString(row.path("id").asText()); }
}
