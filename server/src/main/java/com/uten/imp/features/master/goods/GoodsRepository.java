package com.uten.imp.features.master.goods;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 货品主档仓库。
 *
 * <p>列表查询改用 {@link JpaSpecificationExecutor}（动态：子树 + keyword + 字段精确 + 空值白名单），
 * 范式同 {@code EmployeeRepository} / {@code EmployeeQueryService}。
 */
public interface GoodsRepository extends JpaRepository<Goods, UUID>, JpaSpecificationExecutor<Goods> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Goods> findByLegacyId(Integer legacyId);

    /** 编号查重（仅未软删）—— 手动编号校验用。 */
    boolean existsByCodeAndDeletedFalse(String code);

    /** 编号查重排除自身（编辑改码用）。 */
    boolean existsByCodeAndDeletedFalseAndIdNot(String code, UUID id);

    /**
     * 组装清单写入前按 id 顺序对父件与组件加 KEY SHARE 锁(ADR-111)：与主档删除命令的
     * FOR UPDATE 互斥。删除先拿锁时，这里等它提交后再读到「已删除」并拒绝；这里先拿锁时，
     * 删除等本事务提交后再做引用检查、看见新 BOM 行而拒绝——两边都不会留下「有效 BOM 挂着
     * 已删组件」。KEY SHARE 与 lockUnused 的 NO KEY UPDATE 不冲突，平时建 BOM 不串行。
     */
    @Query(value = """
            SELECT id FROM goods
            WHERE id IN (:ids)
            ORDER BY id FOR KEY SHARE
            """, nativeQuery = true)
    List<UUID> lockForReference(@Param("ids") Collection<UUID> ids);
}
