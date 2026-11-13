; Inno Setup script – built by GitHub Actions (pass /DAppVersion=x.y.z)
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{8F2C1A55-3B7E-4D6A-9C41-2E5A7D9B1F30}
AppName=HB Reader
AppVersion={#AppVersion}
DefaultDirName={autopf}\HB Reader
DefaultGroupName=HB Reader
OutputBaseFilename=HBReader-Setup-{#AppVersion}
OutputDir=Output
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
CloseApplications=yes
RestartApplications=no

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\HB Reader"; Filename: "{app}\hb_reader.exe"
Name: "{autodesktop}\HB Reader"; Filename: "{app}\hb_reader.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop icon"

[Registry]
; open .hb files with HB Reader
Root: HKCU; Subkey: "Software\Classes\.hb"; ValueType: string; ValueData: "HBReader.File"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\HBReader.File\shell\open\command"; ValueType: string; ValueData: """{app}\hb_reader.exe"" ""%1"""; Flags: uninsdeletekey

[Run]
Filename: "{app}\hb_reader.exe"; Description: "Launch HB Reader"; Flags: nowait postinstall
