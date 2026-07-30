package com.uten.imp.features.master.currency;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 币种主档仓库。
 *
 * <p>列表查询用 {@link JpaSpecificationExecutor}（动态：keyword + 字段精确 + 空值白名单），
 * 范式同 {@code ColorRepository}（扁平表，无 categoryId）。
 */
public interface CurrencyRepository extends JpaRepository<Currency, UUID>, JpaSpecificationExecutor<Currency> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Currency> findByLegacyId(Integer legacyId);

    /** 批量按 legacy_id 取未软删记录（单据币种解析用）。 */
    List<Currency> findByLegacyIdInAndDeletedFalse(Collection<Integer> legacyIds);
}
