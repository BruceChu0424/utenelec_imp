package com.uten.imp.features.master.referencemethod;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.List;
import java.util.UUID;

/**
 * <p>管理页列表查询用 {@link JpaSpecificationExecutor}（动态：软删排除 + 表头字段精确
 * + 空值白名单），范式同 {@code ColorRepository}。
 */
public interface SettlementMethodRepository
        extends JpaRepository<SettlementMethod, UUID>, JpaSpecificationExecutor<SettlementMethod> {

    List<SettlementMethod> findByStatusAndDeletedFalseOrderBySortOrderAscCodeAsc(String status);

    boolean existsByNameIgnoreCaseAndDeletedFalse(String name);

    boolean existsByNameIgnoreCaseAndDeletedFalseAndIdNot(String name, UUID id);
}
