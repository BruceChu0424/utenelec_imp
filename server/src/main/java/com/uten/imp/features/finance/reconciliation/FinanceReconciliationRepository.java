package com.uten.imp.features.finance.reconciliation;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.UUID;

/** 账户流水仓库（只读查询；写入由各 finance_*审核 Service 用 EntityManager 直插）。 */
public interface FinanceReconciliationRepository
        extends JpaRepository<FinanceReconciliation, UUID>, JpaSpecificationExecutor<FinanceReconciliation> {
}
