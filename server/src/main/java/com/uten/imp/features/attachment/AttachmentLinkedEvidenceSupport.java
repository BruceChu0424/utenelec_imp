package com.uten.imp.features.attachment;

import com.uten.imp.application.port.AttachmentLinkedEvidencePort;
import com.uten.imp.application.port.AttachmentLinkedEvidencePort.Frozen;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;
import java.util.*;

/** One current-byte/lifecycle authority for frozen original references. No owner is moved. */
@Component @RequiredArgsConstructor
class AttachmentLinkedEvidenceSupport {
    private final AttachmentRepository repository;
    private final ObjectProvider<AttachmentLinkedEvidencePort> providers;
    private static final int MAX_REFERENCES=1000;

    List<Frozen> references(String type,UUID owner){
        var result=new LinkedHashMap<UUID,Frozen>();
        providers.orderedStream().forEach(provider->{
            var refs=provider.linkedEvidence(type,owner);
            if(refs==null)throw unavailable();
            for(var ref:refs){
                if(!valid(ref))throw unavailable();
                var old=result.putIfAbsent(ref.id(),ref);
                if(old!=null&&!sameBinding(old,ref))throw unavailable();
                if(result.size()>MAX_REFERENCES)throw unavailable();
            }
        });
        return List.copyOf(result.values());
    }

    boolean ready(List<Frozen> references){
        if(references==null||references.size()>MAX_REFERENCES)return false;
        if(references.isEmpty())return true;
        if(references.stream().anyMatch(ref->!valid(ref)))return false;
        var rows=load(references);
        var unique=new HashMap<UUID,Frozen>();
        for(var ref:references){
            var old=unique.putIfAbsent(ref.id(),ref);
            if(old!=null&&!sameBinding(old,ref)||!available(rows.get(ref.id()),ref))return false;
        }
        return true;
    }

    List<Attachment> visibleLinked(String type,UUID owner){
        var refs=references(type,owner);if(refs.isEmpty())return List.of();
        var rows=load(refs);
        return refs.stream().filter(ref->available(rows.get(ref.id()),ref)).map(ref->rows.get(ref.id())).toList();
    }
    boolean mayRead(Attachment actual,AuthUser actor){
        if(actual==null||actor==null||actor.isVisitor())return false;
        return providers.orderedStream().anyMatch(provider->provider.readableOriginal(actual.getId(),actor)
                .filter(ref->available(actual,ref)).isPresent());
    }
    void requireMutable(UUID id){
        if(providers.orderedStream().anyMatch(provider->provider.immutableOriginal(id)))
            throw new ApiException(ErrorCode.CONFLICT,"该原稿附件已形成原件依据，请在当前单据补充材料，不能修改或删除原件");
    }
    private Map<UUID,Attachment> load(List<Frozen> refs){
        var rows=new HashMap<UUID,Attachment>();
        repository.findAllById(refs.stream().map(Frozen::id).distinct().toList()).forEach(row->rows.put(row.getId(),row));
        return rows;
    }
    private static boolean available(Attachment row,Frozen ref){
        return row!=null&&valid(ref)&&row.getLifecycleState()==AttachmentLifecycleState.CLEAN&&row.getDeleteRequestedAt()==null
                &&Objects.equals(row.getId(),ref.id())&&Objects.equals(row.getOwnerType(),ref.ownerType())
                &&Objects.equals(row.getOwnerId(),ref.ownerId())&&row.getSha256()!=null&&row.getSha256().equalsIgnoreCase(ref.sha256());
    }
    private static boolean sameBinding(Frozen first,Frozen second){
        return Objects.equals(first.ownerType(),second.ownerType())&&Objects.equals(first.ownerId(),second.ownerId())
                &&first.sha256().equalsIgnoreCase(second.sha256())&&Objects.equals(first.originalName(),second.originalName());
    }
    private static boolean valid(Frozen ref){
        return ref!=null&&ref.id()!=null&&ref.ownerId()!=null&&ref.ownerType()!=null&&ref.ownerType().matches("[A-Z][A-Z0-9_]{0,79}")
                &&ref.sha256()!=null&&ref.sha256().matches("[a-fA-F0-9]{64}");
    }
    private static ApiException unavailable(){return new ApiException(ErrorCode.CONFLICT,"原稿附件依据不完整，请保留原稿核对");}
}
