package com.uten.imp.application.port;
import java.util.*;
/** Internal workflow evidence projection. Owning workflows prove object access before use. */
public interface AttachmentEvidencePort {
    List<Evidence> cleanEvidence(String ownerType,UUID ownerId);
    default boolean frozenEvidenceReady(List<AttachmentLinkedEvidencePort.Frozen> refs){return refs!=null&&refs.isEmpty();}
    record Evidence(UUID id,String sha256,String originalName){}
}
