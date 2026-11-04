package com.uten.imp.features.attachment;
import com.uten.imp.application.port.AttachmentEvidencePort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.*;
@Component
@RequiredArgsConstructor
class AttachmentEvidenceAdapter implements AttachmentEvidencePort {
    private final AttachmentRepository repository;
    @Override public List<Evidence> cleanEvidence(String ownerType,UUID ownerId){
        return repository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(ownerType,ownerId,AttachmentLifecycleState.CLEAN)
            .stream().map(a->new Evidence(a.getId(),a.getSha256(),a.getOriginalName())).toList();
    }
}
