package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;
import java.util.Optional;
import com.uten.imp.security.AuthUser;

/** Internal source SPI. Owning workflows provide only the exact immutable
 * attachment set reviewed for this target, never an entire foreign owner. */
public interface AttachmentLinkedEvidencePort {
    record Frozen(UUID id,String ownerType,UUID ownerId,String sha256,String originalName) { }
    List<Frozen> linkedEvidence(String targetOwnerType,UUID targetOwnerId);
    default boolean immutableOriginal(UUID attachmentId){return false;}
    /** The domain proves a current target reader; attachment owns live owner/hash/scan validation. */
    default Optional<Frozen> readableOriginal(UUID attachmentId,AuthUser actor){return Optional.empty();}
    default boolean mayReadOriginal(UUID attachmentId,AuthUser actor){return readableOriginal(attachmentId,actor).isPresent();}
}
