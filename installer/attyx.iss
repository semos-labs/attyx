; Attyx — Inno Setup installer script
; Build: iscc attyx.iss
; Expects: dist/ folder with attyx.exe, attyx.pdb, share/msys2/...

#define MyAppName "Attyx"
#define MyAppExeName "attyx.exe"
#define MyAppPublisher "Attyx"
#define MyAppURL "https://attyx.dev"

; Version is passed via /DMyAppVersion=x.y.z on the iscc command line.
; Falls back to 0.0.0 for local testing.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{B7A3E2D1-4F5C-4A8B-9E6D-1C2F3A4B5E6D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=attyx-{#MyAppVersion}-setup
SetupIconFile=..\images\attyx.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ChangesEnvironment=yes
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "Add to PATH"; GroupDescription: "Environment:"; Flags: checkedonce
Name: "addcontextmenu"; Description: "Add ""Open Attyx Here"" to Explorer context menu"; GroupDescription: "Shell integration:"; Flags: checkedonce

[Files]
Source: "dist\attyx.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\attyx.pdb"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\share\msys2\*"; DestDir: "{app}\share\msys2"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; "Open Attyx Here" context menu — folder background
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\Attyx"; ValueType: string; ValueName: ""; ValueData: "Open Attyx Here"; Tasks: addcontextmenu; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\Attyx"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: addcontextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\Attyx\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%V"""; Tasks: addcontextmenu; Flags: uninsdeletekey

; "Open Attyx Here" context menu — folder right-click
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Attyx"; ValueType: string; ValueName: ""; ValueData: "Open Attyx Here"; Tasks: addcontextmenu; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Attyx"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: addcontextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Attyx\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%V"""; Tasks: addcontextmenu; Flags: uninsdeletekey

[Code]
// PATH manipulation — add/remove {app} from user PATH

procedure AddToPath();
var
  Path: string;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    Path := '';
  if Pos(ExpandConstant('{app}'), Path) > 0 then
    Exit;
  if Path <> '' then
    Path := Path + ';';
  Path := Path + ExpandConstant('{app}');
  RegWriteStringValue(HKCU, 'Environment', 'Path', Path);
end;

procedure RemoveFromPath();
var
  Path, AppDir: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    Exit;
  AppDir := ExpandConstant('{app}');
  P := Pos(AppDir, Path);
  if P = 0 then
    Exit;
  // Remove the entry and any surrounding semicolons
  Delete(Path, P, Length(AppDir));
  if (P <= Length(Path)) and (Path[P] = ';') then
    Delete(Path, P, 1)
  else if (P > 1) and (Path[P - 1] = ';') then
    Delete(Path, P - 1, 1);
  RegWriteStringValue(HKCU, 'Environment', 'Path', Path);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and IsTaskSelected('addtopath') then
    AddToPath();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveFromPath();
end;
