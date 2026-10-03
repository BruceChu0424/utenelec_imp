package com.uten.imp.config;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import java.util.*;
import java.util.function.Function;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class PlatformDisplayColumnsConfigurationTest {
    private record DisplayRule(Function<PlatformDisplayColumnsConfiguration,PlatformColumnResourceAdapter> factory,
                               Set<String> required, String pricePermission) {}
    private PlatformDisplayColumnsConfiguration config(String... rights) {
        var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"staff",Set.of(rights),false,true,false)));
        return new PlatformDisplayColumnsConfiguration(current);
    }
    @Test void financeReviewerCanUseSamePurchaseAndSubcontractDisplayFieldsWithoutBusinessEditRights() {
        var configuration=config("finance_order_approval:view");
        for(var adapter:List.of(configuration.purchaseDisplayColumns(),configuration.subcontractDisplayColumns())) {
            assertThatCode(()->adapter.requireDefinitionAccess(true)).doesNotThrowAnyException();
            assertThat(adapter.canViewPrice()).isTrue();
            assertThat(adapter.canWrite()).isFalse();
            assertThat(adapter.supportsValues()).isFalse();
            assertThatThrownBy(()->adapter.authorize(Set.of(UUID.randomUUID()),false)).isInstanceOf(ApiException.class);
        }
    }
    @Test void narrowHistoryAndWorkshopReadersGetPersonalColumnsWithoutCostOrRecordWrites() {
        for(String permission:List.of("warehouse_purchase_receipt_history:view","warehouse_subcontract_waste_history:view","workshop_material:view")) {
            var adapter=config(permission).warehouseDisplayColumns();
            assertThatCode(()->adapter.requireDefinitionAccess(true)).doesNotThrowAnyException();
            assertThat(adapter.canViewPrice()).isFalse();
            assertThat(adapter.canWrite()).isFalse();
        }
    }
    @Test void buyerCanConfigureOwnWorkbenchButUnrelatedScopeRemainsForbidden() {
        var configuration=config("purchase_request:view");
        assertThatCode(()->configuration.operationsDisplayColumns().requireDefinitionAccess(true)).doesNotThrowAnyException();
        assertThatThrownBy(()->configuration.payrollDisplayColumns().requireDefinitionAccess(false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->configuration.adminDisplayColumns().requireDefinitionAccess(false)).isInstanceOf(ApiException.class);
    }
    @Test void lossClaimAmountCalculationsFollowTheExistingFinanceAmountAuthority() {
        var ordinary=config("subcontract_loss_claim:view").financeDisplayColumns();
        assertThatCode(()->ordinary.requireDefinitionAccess(false)).doesNotThrowAnyException();
        assertThat(ordinary.canViewPrice()).isFalse();
        assertThat(config("subcontract_loss_claim:view","finance:view:all").financeDisplayColumns().canViewPrice()).isTrue();
    }
    @Test void accountStatementCalculationsRequireEveryExistingStatementPermission() {
        var full=config("account:view","account:balance:view","account:flow:view").accountStatementDisplayColumns();
        assertThatCode(()->full.requireDefinitionAccess(true)).doesNotThrowAnyException();
        assertThat(full.canViewPrice()).isTrue();
        assertThat(full.canWrite()).isFalse();
        assertThat(full.supportsValues()).isFalse();
        assertThat(full.facts()).allMatch(fact->fact.priceProtected());
        assertThat(full.facts()).extracting(fact->fact.key()).containsExactly("inAmount","outAmount","balance");
        assertThatThrownBy(()->full.authorize(Set.of(UUID.randomUUID()),false)).isInstanceOf(ApiException.class);
        for(var rights:List.of(
                new String[]{"account:view","account:flow:view","goods:price:view"},
                new String[]{"account:view","account:balance:view","finance:view:all"},
                new String[]{"account:balance:view","account:flow:view"})) {
            var restricted=config(rights).accountStatementDisplayColumns();
            assertThatThrownBy(()->restricted.requireDefinitionAccess(false)).isInstanceOf(ApiException.class);
            assertThat(restricted.canViewPrice()).isFalse();
        }
    }
    @Test void inventoryWaitingForStockInIsAnIndependentNonFinancialFact() {
        var adapter=config("stock:view").warehouseDisplayColumns();
        assertThat(adapter.facts()).filteredOn(fact->fact.key().equals("pendingStockInQty"))
            .singleElement().satisfies(fact->assertThat(fact.priceProtected()).isFalse());
    }
    @Test void monetaryDisplayScopesUseTheirOwnSourcePermissionsWithoutCrossDomainFallbacks() {
        var rules=List.of(
            new DisplayRule(PlatformDisplayColumnsConfiguration::arApLedgerDisplayColumns,
                Set.of("ar_ap_ledger:view","finance:view:all"),"finance:view:all"),
            new DisplayRule(PlatformDisplayColumnsConfiguration::financeAssetDisplayColumns,
                Set.of("finance_asset:view"),"finance_asset:view"),
            new DisplayRule(PlatformDisplayColumnsConfiguration::supplierSettlementDisplayColumns,
                Set.of("supplier_settlement:view"),"supplier_settlement:view"),
            new DisplayRule(PlatformDisplayColumnsConfiguration::subcontractLossClaimDisplayColumns,
                Set.of("subcontract_loss_claim:view"),"finance:view:all"),
            new DisplayRule(PlatformDisplayColumnsConfiguration::financeOrderApprovalDisplayColumns,
                Set.of("finance_order_approval:view"),"finance_order_approval:view"),
            new DisplayRule(PlatformDisplayColumnsConfiguration::salesQuoteFinanceDisplayColumns,
                Set.of("sales_quote_finance:view"),"sales_quote_finance:view"),
            new DisplayRule(PlatformDisplayColumnsConfiguration::salesOrderFinanceDisplayColumns,
                Set.of("sales_order_finance:view"),"sales_order_finance:view"),
            new DisplayRule(PlatformDisplayColumnsConfiguration::procurementIqcRejectionDisplayColumns,
                Set.of("procurement_iqc_rejection:view"),"procurement_iqc_rejection:amount:view"));
        for(var rule:rules) {
            var own=rule.factory().apply(config(rule.required().toArray(String[]::new)));
            assertThatCode(()->own.requireDefinitionAccess(true)).doesNotThrowAnyException();
            assertThat(own.canViewPrice()).isEqualTo(rule.required().contains(rule.pricePermission()));
            assertThat(own.canWrite()).isFalse();
            assertThat(own.supportsValues()).isFalse();
            assertThat(own.personalDefinitions()).isTrue();
            var fullRights=new HashSet<>(rule.required());fullRights.add(rule.pricePermission());
            assertThat(rule.factory().apply(config(fullRights.toArray(String[]::new))).canViewPrice()).isTrue();
            for(var missing:rule.required()) {
                var unrelated=new HashSet<>(rule.required());unrelated.remove(missing);
                unrelated.addAll(Set.of("goods:price:view","goods:cost:view","finance_receipt:view"));
                var denied=rule.factory().apply(config(unrelated.toArray(String[]::new)));
                assertThatThrownBy(()->denied.requireDefinitionAccess(false)).isInstanceOf(ApiException.class);
                assertThat(denied.canViewPrice()).isFalse();
            }
        }
    }
    @Test void typedDisplayFactsHaveUniqueKeysAndProtectEveryNewMonetarySource() {
        var facts=config("subcontract_loss_claim:view").subcontractLossClaimDisplayColumns().facts();
        assertThat(facts).extracting(PlatformColumnResourceAdapter.FactDefinition::key).doesNotHaveDuplicates();
        var monetary=Set.of("amount","amountOriginal","exchangeRate","amountReceivedOriginal","amountWriteOffOriginal",
            "prepaymentAppliedOriginal","amountBalanceOriginal","amountBalance","grossOriginal","grossLocal",
            "paidOriginal","paidLocal","offsetOriginal","offsetLocal","outstandingOriginal","outstandingLocal",
            "openingBalance","accumulatedAmount","closingBalance","openingBalanceOriginal","periodPostedOriginal",
            "periodPaidOriginal","periodOffsetOriginal","closingBalanceOriginal","unitBookValueLocal","lossBookValueLocal",
            "claimAmountLocal","totalOriginal","clientBalance","valueAtClose","unitCost","appliedAmountOriginal");
        assertThat(facts).filteredOn(fact->monetary.contains(fact.key())).hasSize(monetary.size())
            .allMatch(PlatformColumnResourceAdapter.FactDefinition::priceProtected);
        assertThat(facts).filteredOn(fact->Set.of("qty","actualLossQty","allowedLossQty","excessLossQty","itemCount",
            "planned","remaining","inWeight","outWeight","balanceWeight").contains(fact.key()))
            .hasSize(10).allMatch(fact->!fact.priceProtected());
    }
}
