; Compatibility-validation candidate only; no runtime has passed the target-PC matrix.
; This independent pilot does not modify the existing Windows 10 installer.
; Publishing is NOT connected to the current platform/architecture-only catalog.
#if Ver < 0x06050000
  #error Compatibility pilot requires Inno Setup 6.5 or newer
#endif
#ifndef PayloadLegacyX86
  #error PayloadLegacyX86 is required
#endif
#ifndef PayloadLegacyX64
  #error PayloadLegacyX64 is required
#endif
#ifndef CompanyWebUrl
  #error CompanyWebUrl is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildNumber
  #error BuildNumber is required
#endif
#ifndef AppIcon
  #error AppIcon is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef SetupBaseName
  #error SetupBaseName is required
#endif
#ifndef PolicyInclude
  #error PolicyInclude is required
#endif

[Setup]
AppId=com.uten.uten_imp.compatibility_pilot
AppName=UTEN（兼容验证）
AppVersion={#AppVersion}
AppPublisher=Uten
DefaultDirName={localappdata}\Programs\Uten\UIMP-CompatibilityPilot
DefaultGroupName=UTEN（兼容验证）
UsePreviousAppDir=no
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x86compatible
; Per-user paths require no 64-bit registry or system-directory redirection.
ArchitecturesInstallIn64BitMode=
; Let the policy explain the Win7 SP1 prerequisite itself, including on Win7 SP0.
MinVersion=6.1
UseSetupLdr=yes
OutputDir={#OutputDir}
OutputBaseFilename={#SetupBaseName}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\pilot.ico
VersionInfoCompany=Uten
VersionInfoProductName=Uten IMP Compatibility Validation Pilot
VersionInfoDescription=Uten IMP Compatibility Validation Pilot
VersionInfoVersion={#AppVersion}.{#BuildNumber}
VersionInfoProductVersion={#AppVersion}.{#BuildNumber}
VersionInfoOriginalFileName=UtenIMPCompatibilityPilotSetup.exe
Compression=lzma2
SolidCompression=yes
DiskSpanning=no
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#PayloadLegacyX86}\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: UseRuntime('legacy-x86')
Source: "{#PayloadLegacyX64}\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: UseRuntime('legacy-x64')
Source: "{#AppIcon}"; DestDir: "{app}"; DestName: "pilot.ico"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\UTEN（兼容验证）"; Filename: "{app}\runtime\chrome.exe"; Parameters: "--app=""{#CompanyWebUrl}"" --user-data-dir=""{localappdata}\Uten\UIMP-CompatibilityPilot\Profile"""; WorkingDir: "{app}\runtime"; IconFilename: "{app}\pilot.ico"; AppUserModelID: "com.uten.uten_imp.compatibility_pilot"; Check: UseLegacyRuntime
Name: "{userdesktop}\UTEN（兼容验证）"; Filename: "{app}\runtime\chrome.exe"; Parameters: "--app=""{#CompanyWebUrl}"" --user-data-dir=""{localappdata}\Uten\UIMP-CompatibilityPilot\Profile"""; WorkingDir: "{app}\runtime"; IconFilename: "{app}\pilot.ico"; AppUserModelID: "com.uten.uten_imp.compatibility_pilot"; Check: UseLegacyRuntime

[Run]
; Preserve normal certificate checks, sandboxing and rendering. No debug listener.
Filename: "{app}\runtime\chrome.exe"; Parameters: "--app=""{#CompanyWebUrl}"" --user-data-dir=""{localappdata}\Uten\UIMP-CompatibilityPilot\Profile"""; WorkingDir: "{app}\runtime"; Description: "打开 UTEN（兼容验证）"; Flags: nowait postinstall skipifsilent; Check: UseLegacyRuntime

[Code]
const
  PilotInvalidAttributes = $FFFFFFFF;
  PilotDirectoryAttribute = $10;
  PilotReparseAttribute = $400;

var
  RuntimeDetected: Boolean;
  DetectedVersion: TWindowsVersion;
  DetectedArchitecture: Integer;
  SelectedRuntime: String;

// Generated from the shared policy; do not duplicate the OS decision table here.
#include PolicyInclude

function PilotGetFileAttributes(const Filename: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

procedure DetectRuntime;
begin
  if RuntimeDetected then Exit;
  GetWindowsVersionEx(DetectedVersion);
  DetectedArchitecture := 12;
  if ProcessorArchitecture = paX86 then
    DetectedArchitecture := 0
  else if (ProcessorArchitecture = paX64) and IsWin64 then
    DetectedArchitecture := 9;
  SelectedRuntime := SelectRuntime(DetectedVersion.Major,
    DetectedVersion.Minor, DetectedVersion.ServicePackMajor,
    DetectedArchitecture);
  RuntimeDetected := True;
end;

function UseRuntime(const Target: String): Boolean;
begin
  DetectRuntime;
  Result := (SelectedRuntime <> '') and (SelectedRuntime = Target);
end;

function UseLegacyRuntime: Boolean;
begin
  DetectRuntime;
  Result := (SelectedRuntime = 'legacy-x86') or
    (SelectedRuntime = 'legacy-x64');
end;

function InitializeSetup: Boolean;
begin
  DetectRuntime;
  Result := SelectedRuntime <> '';
  // A different AppId does not isolate Flutter's credential/preferences stores.
  // The pilot must never install or start a second native client on Windows 10+.
  if SelectedRuntime = 'native-x64' then begin
    SuppressibleMsgBox('此电脑继续使用现有 Windows 10 原生客户端。兼容验证程序不会安装、启动或更改该客户端。',
      mbInformation, MB_OK, IDOK);
    Result := False;
    Exit;
  end;
  if not Result then
    SuppressibleMsgBox(RuntimeSelectionError(DetectedVersion.Major,
      DetectedVersion.Minor, DetectedVersion.ServicePackMajor,
      DetectedArchitecture), mbCriticalError, MB_OK, IDOK);
end;

function SafeDirectoryChain(const Path: String): Boolean;
var
  Current, Parent: String;
  Attributes: Cardinal;
  AttributeError: Integer;
begin
  Result := False;
  Current := RemoveBackslashUnlessRoot(ExpandFileName(Path));
  while Current <> '' do begin
    Attributes := PilotGetFileAttributes(Current);
    if Attributes = PilotInvalidAttributes then begin
      AttributeError := DLLGetLastError;
      if (AttributeError <> 2) and (AttributeError <> 3) then Exit;
    end else begin
      if (Attributes and PilotReparseAttribute) <> 0 then Exit;
      if (Attributes and PilotDirectoryAttribute) = 0 then Exit;
    end;
    Parent := ExtractFileDir(Current);
    if CompareText(Parent, Current) = 0 then Break;
    Current := Parent;
  end;
  Result := True;
end;

function SafeExistingTree(const Path: String): Boolean;
var
  Entry: TFindRec;
begin
  Result := SafeDirectoryChain(Path);
  if not Result or not DirExists(Path) then Exit;
  if FindFirst(AddBackslash(Path) + '*', Entry) then begin
    try
      repeat
        if (Entry.Name <> '.') and (Entry.Name <> '..') then begin
          if (Entry.Attributes and PilotReparseAttribute) <> 0 then begin
            Result := False;
            Exit;
          end;
          if (Entry.Attributes and PilotDirectoryAttribute) <> 0 then
            if not SafeExistingTree(AddBackslash(Path) + Entry.Name) then begin
              Result := False;
              Exit;
            end;
        end;
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExpectedDirectory, ActualDirectory, ProfileDirectory: String;
begin
  Result := '';
  DetectRuntime;
  if SelectedRuntime = '' then begin
    Result := RuntimeSelectionError(DetectedVersion.Major,
      DetectedVersion.Minor, DetectedVersion.ServicePackMajor,
      DetectedArchitecture);
    Exit;
  end;
  ExpectedDirectory := RemoveBackslashUnlessRoot(ExpandFileName(
    ExpandConstant('{localappdata}\Programs\Uten\UIMP-CompatibilityPilot')));
  ActualDirectory := RemoveBackslashUnlessRoot(ExpandFileName(WizardDirValue));
  if CompareText(ExpectedDirectory, ActualDirectory) <> 0 then begin
    Result := '兼容验证版仅允许安装到独立的默认目录，请移除 /DIR 参数后重试。';
    Exit;
  end;
  ProfileDirectory := ExpandConstant(
    '{localappdata}\Uten\UIMP-CompatibilityPilot\Profile');
  if not SafeExistingTree(ActualDirectory) or
     not SafeExistingTree(ProfileDirectory) then
    Result := '兼容验证目录或其父目录包含链接、重解析点或无法访问的路径，请先改用普通用户目录。';
end;
