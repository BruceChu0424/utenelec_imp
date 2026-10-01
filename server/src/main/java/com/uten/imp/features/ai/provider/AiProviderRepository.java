package com.uten.imp.features.ai.provider;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** AI 服务商配置存取(只给本包的服务用)。 */
interface AiProviderRepository extends JpaRepository<AiProvider, UUID> {

    @Query("SELECT p FROM AiProvider p WHERE p.deleted=false ORDER BY p.isDefault DESC, p.createdAt ASC")
    List<AiProvider> findAllOrdered();
    @Query("SELECT p FROM AiProvider p WHERE (:onlyDeleted=false OR p.deleted=true) ORDER BY p.createdAt DESC,p.id")
    List<AiProvider> findAllHistory(@Param("onlyDeleted") boolean onlyDeleted);

    /** 改默认、删除等涉及多行不变量的写入先锁全部行(表很小, 按 id 顺序加锁避免死锁)。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT p FROM AiProvider p WHERE p.deleted=false ORDER BY p.id")
    List<AiProvider> lockAll();

    @Query("SELECT p FROM AiProvider p WHERE p.deleted=false AND p.isDefault = true")
    Optional<AiProvider> findDefault();

    @Query("SELECT count(p) > 0 FROM AiProvider p WHERE p.deleted=false AND lower(p.name) = lower(:name) AND p.id <> :excludeId")
    boolean existsByNameIgnoreCaseExcluding(@Param("name") String name, @Param("excludeId") UUID excludeId);
}
