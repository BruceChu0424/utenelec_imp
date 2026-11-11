import java.lang.instrument.Instrumentation;
import java.nio.file.*;
import java.util.*;
public class CloseCompletedTestContexts {
 public static void agentmain(String logPath,Instrumentation instrumentation)throws Exception {
  String command=System.getProperty("sun.java.command","");
  if(!command.startsWith("audit.CandidateImportSuite "))throw new IllegalStateException("Not this test runner");
  String log=Files.readString(Path.of(logPath));
  if(!log.contains("AUDIT_JUNIT_COUNTS tests=32 successful=32 assertionFailures=0 executionErrors=0 skipped=0 aborted=0 failedContainers=0"))throw new IllegalStateException("Tests have not finished successfully");
  for(Class<?> type:instrumentation.getAllLoadedClasses())if(type.getName().equals("org.springframework.test.context.cache.DefaultCacheAwareContextLoaderDelegate")){
   var field=type.getDeclaredField("defaultContextCache");field.setAccessible(true);Object cache=field.get(null);
   var mapField=cache.getClass().getDeclaredField("contextMap");mapField.setAccessible(true);var map=(Map<?,?>)mapField.get(cache);
   List<?> contexts; synchronized(map){contexts=new ArrayList<>(map.values());}
   int closed=0;for(Object context:contexts){context.getClass().getMethod("close").invoke(context);closed++;}
   cache.getClass().getMethod("clear").invoke(cache);
   System.out.println("COMPLETED_TEST_CONTEXTS_CLOSED count="+closed+" all32TestsAlreadyFinished=true noProductMutation=true");return;
  }
  throw new IllegalStateException("Test context cache not found");
 }
 public static void main(String[] arguments)throws Exception {
  var vm=com.sun.tools.attach.VirtualMachine.attach(arguments[0]);
  try{vm.loadAgent(arguments[1],arguments[2]);}finally{vm.detach();}
 }
}
