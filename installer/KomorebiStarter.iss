#ifndef AppVersion
  #error AppVersion must be supplied by the build script.
#endif

#ifndef SourceRoot
  #error SourceRoot must be supplied by the build script.
#endif

#ifndef OutputRoot
  #error OutputRoot must be supplied by the build script.
#endif

[Setup]
AppId={{5FA3F095-B1A1-4B29-BC3F-AA25DDD5902C}
AppName=Komorebi Starter
AppVersion={#AppVersion}
AppVerName=Komorebi Starter {#AppVersion}
AppPublisher=702studio
AppPublisherURL=https://github.com/702studio/komorebi-starter
AppSupportURL=https://github.com/702studio/komorebi-starter/issues
AppUpdatesURL=https://github.com/702studio/komorebi-starter/releases
DefaultDirName={localappdata}\Programs\KomorebiStarter
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputRoot}
OutputBaseFilename=komorebi-starter-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0.22000
ChangesEnvironment=yes
CloseApplications=no
RestartApplications=no
SetupLogging=yes
UninstallDisplayName=Komorebi Starter
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=702studio
VersionInfoDescription=Komorebi Starter per-user installer
VersionInfoProductName=Komorebi Starter
VersionInfoProductVersion={#AppVersion}

[Tasks]
Name: "migrate"; Description: "Migrate the current GlazeWM startup"; Flags: unchecked
Name: "fonts"; Description: "Install JetBrains Mono Nerd Font"; Flags: unchecked

[Files]
Source: "{#SourceRoot}\install.ps1"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\uninstall.ps1"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\restore.ps1"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\agent-manifest.json"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\LICENSE"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\README.md"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\AGENTS.md"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "{#SourceRoot}\config\*"; DestDir: "{app}\payload\config"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\scripts\start.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\doctor.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\FocusInterop.cs"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\FocusInterop.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\focus-diagnostics.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\wm.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\wm.cmd"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\wm-resize-mode.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\KomorebiStarter.Common.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\change_scale.ps1"; DestDir: "{app}\payload\scripts"; Flags: ignoreversion

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -Force -Quiet"; Flags: waituntilterminated runhidden; RunOnceId: "KomorebiStarterProductUninstall"; Check: ShouldRunProductUninstaller

[Code]
function HasCommandLineSwitch(const SwitchName: String): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to ParamCount do
  begin
    if CompareText(ParamStr(Index), SwitchName) = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function ShouldRunProductUninstaller: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\uninstall.ps1')) and
    FileExists(ExpandConstant('{localappdata}\KomorebiStarter\install-manifest.json'));
end;

function BuildInstallParameters: String;
begin
  Result := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\payload\install.ps1') +
    '" -Preset Minimal -NonInteractive -Quiet';

  if HasCommandLineSwitch('/WINGET') then
    Result := Result + ' -SkipDependencies';

  if WizardIsTaskSelected('migrate') or HasCommandLineSwitch('/MIGRATEFROMGLAZEWM') then
    Result := Result + ' -MigrateFromGlazeWM';

  if WizardIsTaskSelected('fonts') or HasCommandLineSwitch('/INSTALLFONTS') then
    Result := Result + ' -InstallFonts';

  if HasCommandLineSwitch('/FORCE') then
    Result := Result + ' -Force';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShellPath: String;
  Parameters: String;
begin
  if CurStep <> ssPostInstall then
    Exit;

  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := BuildInstallParameters;
  Log('Running transactional Komorebi Starter installation.');

  if not Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) then
    RaiseException('Unable to start the Komorebi Starter installation engine.');

  if ResultCode <> 0 then
    RaiseException(Format('Komorebi Starter installation failed with exit code %d. Review the setup log.', [ResultCode]));
end;
