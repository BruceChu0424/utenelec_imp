package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.StorageProperties;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** Explicit historical-catalog seeds and audited synthetic bytes; never a production catalog. */
final class ClientReleaseFixtures {
    private ClientReleaseFixtures() { }
    static ClientReleaseDto.Release legacyDraft(ClientUpdateProperties properties, ObjectMapper mapper, ClientReleaseDto.Create request, String mode) {
        var release=new ClientReleaseDto.Release(request.requestId(),request.platform(),request.architecture(),request.version(),request.buildNumber(),
                request.releaseNotes()==null?"":request.releaseNotes().strip(),request.mandatory(),request.fileName(),request.expectedSha256(),null,0,mode,
                request.storeUrl(),"/api/client-updates/"+request.requestId()+"/download","DRAFT",Instant.now(),null,request.packageKind(),request.runtimeFamily());
        var catalog=new ClientReleaseCatalog(properties,new StorageProperties(),mapper);
        catalog.locked(root->{catalog.write(root,release);return null;});
        return release;
    }
    static byte[] windows(ObjectMapper mapper,long build,String architecture,String version) throws Exception {
        var files=new LinkedHashMap<String,byte[]>();
        files.put("uten_imp.exe",WindowsFlutterFixture.main(build,architecture,version));
        files.put("flutter_windows.dll",WindowsFlutterFixture.engine(build,architecture,version));
        files.put("data/app.so",WindowsFlutterFixture.elf(architecture));
        files.put("data/icudtl.dat","icu".getBytes(StandardCharsets.UTF_8));
        files.put("data/flutter_assets/AssetManifest.bin","assets".getBytes(StandardCharsets.UTF_8));
        var entries=new ArrayList<Map<String,Object>>();files.forEach((name,value)->entries.add(Map.of("path",name,"size",value.length,"sha256",sha(value))));
        files.put("uten-client-manifest.json",mapper.writeValueAsBytes(Map.of("schemaVersion",1,"platform","windows","architecture",architecture,
                "version",version,"buildNumber",build,"executable","uten_imp.exe","packageKind","update","files",entries)));
        return zip(files);
    }
    static byte[] zip(Map<String,byte[]> files) throws Exception {
        var output=new ByteArrayOutputStream();try(var zip=new ZipOutputStream(output)){for(var file:files.entrySet()){zip.putNextEntry(new ZipEntry(file.getKey()));zip.write(file.getValue());zip.closeEntry();}}
        return output.toByteArray();
    }
    static String sha(byte[] bytes){return HexFormat.of().formatHex(ClientPackageInspector.digest().digest(bytes));}
}
