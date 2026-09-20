package com.uten.imp.features.expenseclaim;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface ExpenseClaimEventRepository
        extends JpaRepository<ExpenseClaimEvent, UUID> {

    List<ExpenseClaimEvent> findByClaimIdInOrderByCreatedAtAscIdAsc(List<UUID> claimIds);

    List<ExpenseClaimEvent> findByClaimIdOrderByCreatedAtAscIdAsc(UUID claimId);
}
