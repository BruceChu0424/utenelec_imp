package com.uten.imp.features.finance.asset.application;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CommercialPriceVisibility;
import jakarta.persistence.EntityManager;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/** Reuses the asset workbench's global authorization and original row lifecycle. */
@Configuration(proxyBeanMethods = false)
public class FinanceAssetAttachmentAccessConfiguration {
    @Bean
    AttachmentOwnerAccessPolicy financeAssetAttachmentAccessPolicy(
            EntityManager em, FinanceAssetAuthorization authorization, CommercialPriceVisibility prices) {
        return new AssetFilePolicy("FINANCE_ASSET", "fixed_assets", em, authorization, prices);
    }

    @Bean
    AttachmentOwnerAccessPolicy financeDeferredExpenseAttachmentAccessPolicy(
            EntityManager em, FinanceAssetAuthorization authorization, CommercialPriceVisibility prices) {
        return new AssetFilePolicy("FINANCE_DEFERRED_EXPENSE", "deferred_expenses", em, authorization, prices);
    }

    public static class AssetFilePolicy implements AttachmentOwnerAccessPolicy {
        private final String ownerType;
        private final String table;
        private final EntityManager em;
        private final FinanceAssetAuthorization authorization;
        private final CommercialPriceVisibility prices;

        AssetFilePolicy(String ownerType, String table, EntityManager em,
                        FinanceAssetAuthorization authorization, CommercialPriceVisibility prices) {
            this.ownerType = ownerType;
            this.table = table;
            this.em = em;
            this.authorization = authorization;
            this.prices = prices;
        }

        @Override public String ownerType() { return ownerType; }

        @Override
        @Transactional(readOnly = true)
        public void requireCanView(UUID ownerId, AuthUser user) {
            readable();
            status(ownerId, false);
        }

        @Override
        @Transactional(readOnly = true)
        public void requireCanManage(UUID ownerId, AuthUser user) {
            manageable();
            draft(status(ownerId, false));
        }

        @Override
        @Transactional(propagation = Propagation.MANDATORY)
        public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
            manageable();
            // Same original row lock as submit/update/delete; no posting tables are touched.
            String current = status(ownerId, true);
            manageable();
            draft(current);
        }

        private void readable() {
            authorization.require(FinanceAssetAuthorization.VIEW);
            if (!prices.canViewFinance()) {
                throw new ApiException(ErrorCode.FORBIDDEN, "资产原件可能包含金额，需要财务金额查看权限");
            }
        }

        private void manageable() {
            readable();
            authorization.require(FinanceAssetAuthorization.EDIT);
        }

        private String status(UUID ownerId, boolean forUpdate) {
            if (ownerId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先保存资产记录再添加文件");
            // table comes only from the two fixed bean declarations, never from a request.
            @SuppressWarnings("unchecked")
            List<String> rows = em.createNativeQuery("SELECT lifecycle_status FROM " + table
                            + " WHERE id=:id AND is_deleted=false" + (forUpdate ? " FOR UPDATE" : ""))
                    .setParameter("id", ownerId).getResultList();
            if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "资产记录不存在");
            return rows.getFirst();
        }

        private static void draft(String status) {
            if (!"DRAFT".equals(status)) {
                throw new ApiException(ErrorCode.CONFLICT, "只有草稿资产可以添加或删除文件");
            }
        }
    }
}
