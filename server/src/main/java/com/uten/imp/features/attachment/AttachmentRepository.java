package com.uten.imp.features.attachment;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface AttachmentRepository extends JpaRepository<Attachment, UUID> {

    List<Attachment> findByOwnerTypeAndOwnerIdOrderByCreatedAtAsc(String ownerType, UUID ownerId);

    List<Attachment> findByOwnerTypeAndOwnerIdInOrderByCreatedAtAsc(String ownerType, Collection<UUID> ownerIds);

    Optional<Attachment> findByStorageKey(String storageKey);
}
