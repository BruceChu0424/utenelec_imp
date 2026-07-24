package com.uten.imp.features.master.client;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 客户主档仓库。与 MouldRepository 同构，额外提供子树汇总查询（分组节点点击时
 * 返回该分类及所有后代分类下的客户——客户主档会直接挂在有子分类的节点上，
 * 如「外贸(钟)」既有子分类「内销轨道」又直接挂客户）。
 */
public interface ClientRepository extends JpaRepository<Client, UUID> {

    /** 某分类下的客户（未软删），按 id 升序。 */
    Page<Client> findByCategoryIdAndDeletedFalseOrderById(UUID categoryId, Pageable pageable);

    /** 多分类下的客户（未软删）——分组节点子树汇总用。 */
    Page<Client> findByCategoryIdInAndDeletedFalseOrderById(
            List<UUID> categoryIds, Pageable pageable);

    /** 全部客户（未软删，categoryId 为 null 时用）。 */
    Page<Client> findByDeletedFalseOrderById(Pageable pageable);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Client> findByLegacyId(Integer legacyId);
}
