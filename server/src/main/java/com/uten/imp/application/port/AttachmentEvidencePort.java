package com.uten.imp.application.port;
import java.util.*;
/** Internal workflow evidence projection. Owning workflows prove object access before use. */
public interface AttachmentEvidencePort {
    List<Evidence> cleanEvidence(String ownerType,UUID ownerId);
    record Evidence(UUID id,String sha256,String originalName){}
}
