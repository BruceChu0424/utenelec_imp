package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.UUID;

/** Explicit read-only real-producer metadata probe. No ZIP, catalog, process or application is created. */
public final class FlutterProducerMetadataIntegration {
    private FlutterProducerMetadataIntegration() { }
    public static void main(String[] arguments) throws Exception {
        if(arguments.length!=4) throw new IllegalArgumentException("Expected existing Release directory, architecture, version, build");
        Path root=Path.of(arguments[0]).toAbsolutePath().normalize();
        if(!"Release".equals(root.getFileName().toString())) throw new IllegalArgumentException("Expected existing Release output");
        long build=Long.parseLong(arguments[3]);
        var release=new ClientReleaseDto.Release(UUID.randomUUID(),"windows",arguments[1],arguments[2],build,"",false,"metadata-only",null,null,0,
                "windows_archive",null,null,"DRAFT",Instant.now(),null,"update","flutter","paired_v1");
        byte[] main=read(root.resolve("uten_imp.exe"),32*1024*1024,false), engine=read(root.resolve("flutter_windows.dll"),1048576,true), aot=read(root.resolve("data/app.so"),64,true);
        var pe=WindowsFlutterPackageInspector.class.getDeclaredMethod("pe",byte[].class,String.class,boolean.class);pe.setAccessible(true);
        var version=WindowsFlutterPackageInspector.class.getDeclaredMethod("version",byte[].class,pe.getReturnType(),ClientReleaseDto.Release.class);version.setAccessible(true);
        version.invoke(null,main,pe.invoke(null,main,arguments[1],false),release);pe.invoke(null,engine,arguments[1],true);NativeBinaryArchitecture.elf(aot,arguments[1]);
        var report=new LinkedHashMap<String,Object>();report.put("passed",true);report.put("scope","metadata-only existing producer files; no package created or application started");
        report.put("directory",root.toString());report.put("architecture",arguments[1]);report.put("version",arguments[2]);report.put("buildNumber",build);
        var files=new LinkedHashMap<String,Object>();for(String name:java.util.List.of("uten_imp.exe","flutter_windows.dll","data/app.so")) {
            Path path=root.resolve(name);var digest=ClientPackageInspector.digest();try(var input=Files.newInputStream(path)){byte[] buffer=new byte[65536];for(int n;(n=input.read(buffer))!=-1;)digest.update(buffer,0,n);}
            files.put(name,java.util.Map.of("sizeBytes",Files.size(path),"sha256",java.util.HexFormat.of().formatHex(digest.digest())));
        }
        report.put("files",files);System.out.println(new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsString(report));
    }
    private static byte[] read(Path path,int maximum,boolean prefix)throws Exception {
        if(!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)||Files.size(path)<64||!prefix&&Files.size(path)>maximum)throw new IllegalArgumentException("Invalid existing producer file");
        try(var input=Files.newInputStream(path)){return input.readNBytes(maximum);}
    }
}
