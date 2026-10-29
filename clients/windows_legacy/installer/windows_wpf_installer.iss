; Native WPF compatibility-validation candidate. Not certified on Win7 hardware.
; Independent from the Flutter installer, SDK, profile and client-release catalog.
; No download, .NET installation, system CA write or publication is performed.
#if Ver < 0x06050000
  #error WPF compatibility installer requires Inno Setup 6.5 or newer
#endif
#ifndef PayloadX86
  #error PayloadX86 is required
#endif
#ifndef PayloadX64
  #error PayloadX64 is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef Version
  #error Version is required
#endif
#ifndef BuildNumber
  #error BuildNumber is required
#endif
#ifndef AppIcon
  #error AppIcon is required
#endif
#ifndef AppConfiguration
  #error AppConfiguration is required
#endif
#ifndef UpdaterX86
  #error UpdaterX86 is required
#endif
#ifndef UpdaterX64
  #error UpdaterX64 is required
#endif
#ifdef ValidationFixture
  #define InstallerAppId "com.uten.uten_imp.win7_wpf.fixture"
  #define InstallerAppName "UTEN WPF Installer Fixture - DO NOT DISTRIBUTE"
  #define InstallerDirectory "UIMP-Win7-WPF-Fixture"
  #define InstallerProduct "Uten IMP WPF Non-installable Fixture"
#else
  #define InstallerAppId "com.uten.uten_imp.win7_wpf"
  #define InstallerAppName "UTEN（Win7兼容版）"
  #define InstallerDirectory "UIMP-Win7-WPF"
  #define InstallerProduct "Uten IMP Native WPF Compatibility Validation"
#endif

[Setup]
AppId={#InstallerAppId}
AppName={#InstallerAppName}
AppVersion={#Version}
AppPublisher=Uten
DefaultDirName={localappdata}\Programs\Uten\{#InstallerDirectory}
DefaultGroupName={#InstallerAppName}
UsePreviousAppDir=no
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x86compatible
ArchitecturesInstallIn64BitMode=
; .NET 4.8 targets Win7 SP1; loader and policy both reject an older system.
MinVersion=6.1sp1
UseSetupLdr=yes
OutputDir={#OutputDir}
OutputBaseFilename=UtenWin7WpfSetup-{#Version}-{#BuildNumber}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\uten-wpf.ico
VersionInfoCompany=Uten
VersionInfoProductName={#InstallerProduct}
VersionInfoDescription={#InstallerProduct}
VersionInfoVersion={#Version}.{#BuildNumber}
VersionInfoProductVersion={#Version}.{#BuildNumber}
VersionInfoOriginalFileName=UtenWin7WpfSetup.exe
Compression=lzma2
SolidCompression=yes
DiskSpanning=no
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
SetupMutex=UtenWin7WpfInstaller

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Payloads retain their fixed .exe.config runtime settings. Company endpoints
; come exclusively from the separately reviewed uten.client.json input.
; Exactly five runtime leaves + the separately bound connection file. Never
; recursively copy a development output, PDB, tests, prior job or updater ZIP.
Source: "{#PayloadX86}\Uten.Legacy.Desktop.exe"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x86')
Source: "{#PayloadX86}\Uten.Legacy.Core.dll"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x86')
Source: "{#PayloadX86}\BouncyCastle.Cryptography.dll"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x86')
Source: "{#PayloadX86}\Uten.Legacy.Desktop.exe.config"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x86')
Source: "{#PayloadX86}\BouncyCastle-LICENSE.md"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x86')
Source: "{#PayloadX64}\Uten.Legacy.Desktop.exe"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x64')
Source: "{#PayloadX64}\Uten.Legacy.Core.dll"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x64')
Source: "{#PayloadX64}\BouncyCastle.Cryptography.dll"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x64')
Source: "{#PayloadX64}\Uten.Legacy.Desktop.exe.config"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x64')
Source: "{#PayloadX64}\BouncyCastle-LICENSE.md"; DestDir: "{app}"; Flags: ignoreversion; Check: UseArchitecture('x64')
; Fixed bootstrap is installed only by this full Setup, never by update ZIP.
Source: "{#UpdaterX86}"; DestDir: "{app}\client_updater"; DestName: "Uten.Legacy.Updater.exe"; Flags: ignoreversion; Check: UseArchitecture('x86')
Source: "{#UpdaterX86}.config"; DestDir: "{app}\client_updater"; DestName: "Uten.Legacy.Updater.exe.config"; Flags: ignoreversion; Check: UseArchitecture('x86')
Source: "{#UpdaterX64}"; DestDir: "{app}\client_updater"; DestName: "Uten.Legacy.Updater.exe"; Flags: ignoreversion; Check: UseArchitecture('x64')
Source: "{#UpdaterX64}.config"; DestDir: "{app}\client_updater"; DestName: "Uten.Legacy.Updater.exe.config"; Flags: ignoreversion; Check: UseArchitecture('x64')
Source: "{#AppConfiguration}"; DestDir: "{app}"; DestName: "uten.client.json"; Flags: ignoreversion
Source: "{#AppIcon}"; DestDir: "{app}"; DestName: "uten-wpf.ico"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#InstallerAppName}"; Filename: "{app}\Uten.Legacy.Desktop.exe"; WorkingDir: "{app}"; IconFilename: "{app}\uten-wpf.ico"; AppUserModelID: "{#InstallerAppId}"
Name: "{userdesktop}\{#InstallerAppName}"; Filename: "{app}\Uten.Legacy.Desktop.exe"; WorkingDir: "{app}"; IconFilename: "{app}\uten-wpf.ico"; AppUserModelID: "{#InstallerAppId}"

[Run]
Filename: "{app}\Uten.Legacy.Desktop.exe"; WorkingDir: "{app}"; Description: "打开 UTEN（Win7兼容版）"; Flags: nowait postinstall skipifsilent

[Code]
type
  TCheckedFileInformation = record
    Attributes, CreatedLow, CreatedHigh, AccessedLow, AccessedHigh: Cardinal;
    WrittenLow, WrittenHigh, Volume, SizeHigh, SizeLow: Cardinal;
    LinkCount, IndexHigh, IndexLow: Cardinal;
  end;
const
  InvalidAttributes = $FFFFFFFF;
  DirectoryAttribute = $10;
  ReparseAttribute = $400;

var
  SystemDetected: Boolean;
  DetectedVersion: TWindowsVersion;
  DetectedArchitecture: Integer;
  SelectedArchitecture: String;
  InstallerUpdateLock: Integer;

// Shared facts and policy are generated and verified by wpf_install_policy.py.
#include "wpf_install_policy.iss"

function CheckedGetFileAttributes(const Filename: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function CheckedOpenFile(const Filename: String; Access, Share: Cardinal;
  Security: Integer; Creation, Flags: Cardinal; Template: Integer): Integer;
  external 'CreateFileW@kernel32.dll stdcall';
function CheckedFileInformation(Handle: Integer; var Information: TCheckedFileInformation): Boolean;
  external 'GetFileInformationByHandle@kernel32.dll stdcall';
function CheckedCloseHandle(Handle: Integer): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function SafeOrdinaryFile(const Filename: String): Boolean;
var
  Handle: Integer;
  Information: TCheckedFileInformation;
begin
  Result := False;
  Handle := CheckedOpenFile(Filename, $80, 7, 0, 3, $00200000, 0);
  if Handle = -1 then Exit;
  try
    Result := CheckedFileInformation(Handle, Information) and
      ((Information.Attributes and (DirectoryAttribute or ReparseAttribute)) = 0) and
      (Information.LinkCount = 1);
  finally
    CheckedCloseHandle(Handle);
  end;
end;

procedure DetectSystem;
begin
  if SystemDetected then Exit;
  GetWindowsVersionEx(DetectedVersion);
  DetectedArchitecture := 12;
  if ProcessorArchitecture = paX86 then
    DetectedArchitecture := 0
  else if (ProcessorArchitecture = paX64) and IsWin64 then
    DetectedArchitecture := 9;
  SystemDetected := True;
end;

function FrameworkRelease: Cardinal;
var
  RegistryRoot: Integer;
begin
  DetectSystem;
  Result := 0;
  RegistryRoot := HKLM32;
  if DetectedArchitecture = 9 then RegistryRoot := HKLM64;
  // Microsoft's key is NET Framework Setup, not .NETFramework.
  // 528040 is the minimum 4.8 value across OSes; Win7/8.1 normally use 528049.
  RegQueryDWordValue(RegistryRoot,
    'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Result);
end;

function ValidateSystem: String;
begin
  DetectSystem;
  SelectedArchitecture := SelectWpfArchitecture(DetectedVersion.Major,
    DetectedVersion.Minor, DetectedVersion.ServicePackMajor,
    DetectedArchitecture, DetectedVersion.ProductType, FrameworkRelease, Result);
end;

function UseArchitecture(const Architecture: String): Boolean;
begin
  Result := SelectedArchitecture = Architecture;
end;

function InitializeSetup: Boolean;
var
  ErrorMessage: String;
begin
#ifdef ValidationFixture
  // Compiled fixture validates syntax and bindings only. It must never install
  // its inert process test payload on any computer.
  SuppressibleMsgBox('这是不可安装、不可分发的安装器编译夹具。', mbCriticalError, MB_OK, IDOK);
  Result := False;
  Exit;
#endif
  ErrorMessage := ValidateSystem;
  Result := (ErrorMessage = '') and (SelectedArchitecture <> '');
  if not Result then
    SuppressibleMsgBox(ErrorMessage, mbCriticalError, MB_OK, IDOK);
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
    Attributes := CheckedGetFileAttributes(Current);
    if Attributes = InvalidAttributes then begin
      AttributeError := DLLGetLastError;
      if (AttributeError <> 2) and (AttributeError <> 3) then Exit;
    end else begin
      if (Attributes and ReparseAttribute) <> 0 then Exit;
      if (Attributes and DirectoryAttribute) = 0 then Exit;
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
          if (Entry.Attributes and ReparseAttribute) <> 0 then begin
            Result := False;
            Exit;
          end;
          if (Entry.Attributes and DirectoryAttribute) <> 0 then begin
            if not SafeExistingTree(AddBackslash(Path) + Entry.Name) then begin
              Result := False;
              Exit;
            end;
          end else if not SafeOrdinaryFile(AddBackslash(Path) + Entry.Name) then begin
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
  Result := ValidateSystem;
  if Result <> '' then Exit;
  ExpectedDirectory := RemoveBackslashUnlessRoot(ExpandFileName(
    ExpandConstant('{localappdata}\Programs\Uten\{#InstallerDirectory}')));
  ActualDirectory := RemoveBackslashUnlessRoot(ExpandFileName(WizardDirValue));
  if CompareText(ExpectedDirectory, ActualDirectory) <> 0 then begin
    Result := '当前验证版仅允许使用独立默认目录，请移除 /DIR 参数后重试。';
    Exit;
  end;
  ProfileDirectory := ExpandConstant('{localappdata}\Uten\UIMP-Win7-WPF');
  if not SafeExistingTree(ActualDirectory) or not SafeExistingTree(ProfileDirectory) then begin
    Result := '安装目录或兼容版配置目录包含链接、重解析点、硬链接或无法访问的路径，不能继续安装。';
    Exit;
  end;
  if DirExists(AddBackslash(ActualDirectory) + 'client_updater') and (InstallerUpdateLock = 0) then begin
    InstallerUpdateLock := CheckedOpenFile(AddBackslash(ActualDirectory) + 'client_updater\update.lock',
      $C0000000, 0, 0, 4, $00200000, 0);
    if InstallerUpdateLock = -1 then begin
      InstallerUpdateLock := 0;
      Result := '原生更新组件正在使用或更新目录无法独占访问，安装不会覆盖当前程序。请完成更新后重试。';
    end;
  end;
end;

procedure DeinitializeSetup;
begin
  if InstallerUpdateLock <> 0 then begin
    CheckedCloseHandle(InstallerUpdateLock);
    InstallerUpdateLock := 0;
  end;
end;
