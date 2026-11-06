; Public synthetic VERSIONINFO fixture only. No ERP/runtime/customer payload.
[Setup]
AppId=com.uten.test.version_resource_fixture
AppName=UTEN public metadata fixture
AppVersion=2.5.31
DefaultDirName={tmp}\UTEN-Public-Metadata-Fixture
PrivilegesRequired=lowest
Uninstallable=no
DisableProgramGroupPage=yes
UseSetupLdr=yes
Compression=none
VersionInfoCompany=Uten
VersionInfoVersion=2.5.31.2531
VersionInfoTextVersion=2.5.31.2531
VersionInfoProductVersion=2.5.31.2531
VersionInfoProductTextVersion=2.5.31.2531
#ifdef LocalTest
VersionInfoProductName=Uten IMP Windows Local Test Setup
VersionInfoOriginalFileName=UtenIMPLocalTestSetup.exe
VersionInfoDescription=Uten IMP Windows Local Test Setup (x64)
#else
VersionInfoProductName=Uten IMP Windows Setup
VersionInfoOriginalFileName=UtenIMPSetup.exe
VersionInfoDescription=Uten IMP Windows Setup (x64)
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "payload.txt"; DestDir: "{app}"; Flags: ignoreversion
