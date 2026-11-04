package com.uten.imp.features.attachment;
import com.uten.imp.application.port.AttachmentEvidencePort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.*;
@Component
@RequiredArgsConstructor
class AttachmentEvidenceAdapter implements AttachmentEvidencePort {
    private final AttachmentRepository repository;
    @org.springframework.beans.factory.annotation.Autowired
    private AttachmentLinkedEvidenceSupport linked;
    @Override public List<Evidence> cleanEvidence(String ownerType,UUID ownerId){
        var result=new LinkedHashMap<UUID,Evidence>();
        repository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(ownerType,ownerId,AttachmentLifecycleState.CLEAN)
            .stream().filter(a->a.getDeleteRequestedAt()==null&&a.getSha256()!=null&&!a.getSha256().isBlank())
            .forEach(a->result.put(a.getId(),new Evidence(a.getId(),a.getSha256(),a.getOriginalName())));
        if(linked!=null)linked.visibleLinked(ownerType,ownerId).forEach(a->result.putIfAbsent(a.getId(),new Evidence(a.getId(),a.getSha256(),a.getOriginalName())));
        return List.copyOf(result.values());
    }
    @Override public boolean frozenEvidenceReady(List<com.uten.imp.application.port.AttachmentLinkedEvidencePort.Frozen> refs){
        return refs!=null&&refs.isEmpty()||linked!=null&&linked.ready(refs);
    }
}
