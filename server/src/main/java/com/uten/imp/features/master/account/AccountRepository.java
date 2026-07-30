package com.uten.imp.features.master.account;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 账户主档仓库。
 *
 * <p>扁平主档，列表查询用 {@link JpaSpecificationExecutor}（动态：keyword + 字段精确 + 空值白名单），
 * 范式同 {@code CurrencyRepository}。
 */
public interface AccountRepository extends JpaRepository<Account, UUID>, JpaSpecificationExecutor<Account> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Account> findByLegacyId(Integer legacyId);

    /** 批量按 legacy_id 取未软删记录（单据账户解析用）。 */
    List<Account> findByLegacyIdInAndDeletedFalse(Collection<Integer> legacyIds);
}
