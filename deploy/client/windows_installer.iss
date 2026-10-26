; Standard first installation only. Application updates use the installed updater.
; Requires Inno Setup 6.5+ with its bundled Simplified Chinese translation.
#if Ver < 0x06050000
  #error UIMP Setup requires Inno Setup 6.5 or newer
#endif
#ifndef PayloadDir
  #error PayloadDir must be supplied by build_windows_installer.py
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by build_windows_installer.py
#endif
#ifndef AppVersion
  #error AppVersion must be supplied by build_windows_installer.py
#endif
#ifndef BuildNumber
  #error BuildNumber must be supplied by build_windows_installer.py
#endif
#ifndef PayloadArchitecture
  #error PayloadArchitecture must be supplied by build_windows_installer.py
#endif
#ifndef AllowedArchitectures
  #error AllowedArchitectures must be supplied by build_windows_installer.py
#endif
#ifndef Install64Architectures
  #error Install64Architectures must be supplied by build_windows_installer.py
#endif
#ifndef SetupBaseName
  #error SetupBaseName must be supplied by build_windows_installer.py
#endif
#ifndef AppIcon
  #error AppIcon must be supplied by build_windows_installer.py
#endif

[Setup]
#ifdef LocalTest
AppId=com.uten.uten_imp.local_test
DefaultDirName={localappdata}\Programs\Uten\UIMP-LocalTest
#else
AppId=com.uten.uten_imp
DefaultDirName={localappdata}\Programs\Uten\UIMP
#endif
AppName={cm:AppDisplayName}
AppVersion={#AppVersion}
AppPublisher=Uten
DefaultGroupName={cm:AppDisplayName}
DisableDirPage=yes
DisableProgramGroupPage=yes
#ifdef LocalTest
UsePreviousAppDir=no
#else
UsePreviousAppDir=yes
#endif
UsePreviousLanguage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#AllowedArchitectures}
ArchitecturesInstallIn64BitMode={#Install64Architectures}
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#SetupBaseName}
SetupIconFile={#AppIcon}
UninstallDisplayName={cm:AppDisplayName}
UninstallDisplayIcon={app}\uten_imp.exe
Compression=lzma2
SolidCompression=yes
DiskSpanning=no
; yes deliberately fixes the outer loader to x86. Payload architecture is separate.
UseSetupLdr=yes
#ifdef LocalTest
VersionInfoProductName=Uten IMP Windows Local Test Setup
VersionInfoOriginalFileName=UtenIMPLocalTestSetup.exe
VersionInfoDescription=Uten IMP Windows Local Test Setup ({#PayloadArchitecture})
#else
VersionInfoProductName=Uten IMP Windows Setup
VersionInfoOriginalFileName=UtenIMPSetup.exe
VersionInfoDescription=Uten IMP Windows Setup ({#PayloadArchitecture})
#endif
VersionInfoCompany=Uten
VersionInfoVersion={#AppVersion}.{#BuildNumber}
VersionInfoTextVersion={#AppVersion}.{#BuildNumber}
VersionInfoProductVersion={#AppVersion}.{#BuildNumber}
VersionInfoProductTextVersion={#AppVersion}.{#BuildNumber}
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[CustomMessages]
#ifdef LocalTest
english.AppDisplayName=UTEN - 本地测试
chinesesimp.AppDisplayName=UTEN - 本地测试
english.LaunchUimp=Open UTEN - Local Test
chinesesimp.LaunchUimp=打开 UTEN - 本地测试
#else
english.AppDisplayName=UTEN
chinesesimp.AppDisplayName=UTEN
english.LaunchUimp=Open UTEN
chinesesimp.LaunchUimp=打开 UTEN
#endif

[Files]
; PayloadDir contains only the validated runtime, fixed updater and manifest.
; The intermediate ZIP is outside this directory and is never embedded twice.
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{cm:AppDisplayName}"; Filename: "{app}\uten_imp.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\{cm:AppDisplayName}"; Filename: "{app}\uten_imp.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\uten_imp.exe"; Description: "{cm:LaunchUimp}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
