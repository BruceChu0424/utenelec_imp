package com.uten.imp.features.expenseclaim;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface ExpenseClaimItemRepository extends JpaRepository<ExpenseClaimItem, UUID> {

    List<ExpenseClaimItem> findByClaimIdInOrderByClaimIdAscLineNoAsc(Collection<UUID> claimIds);

    @Modifying
    @Query("DELETE FROM ExpenseClaimItem i WHERE i.claimId = :claimId")
    int deleteByClaimId(@Param("claimId") UUID claimId);
}
