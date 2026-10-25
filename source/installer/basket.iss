; ملف تثبيت Basket لـ Windows (Inno Setup 6).
; البناء: tool\build_installer.ps1 (بيبني البرنامج وبيجهز ملفات Windows الناقصة وبيعمل الـ Setup).
#define AppName "Basket"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\builds"
#endif

[Setup]
; المعرّف ده لازم يفضل ثابت عشان التحديثات تتسطب فوق النسخة القديمة
AppId={{B8F6DE99-8C1A-45EF-BFE0-7D943AEA9F8A}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Basket
DefaultDirName={autopf}\Basket
DefaultGroupName=Basket
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Basket-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\basket.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Languages]
Name: "arabic"; MessagesFile: "compiler:Languages\Arabic.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
arabic.DesktopIcon=أيقونة على سطح المكتب
arabic.AutoStart=شغّل Basket لوحده مع تشغيل الكمبيوتر (مهم لو الجهاز ده هو سيرفر المحل)
arabic.LaunchApp=افتح Basket دلوقتي
english.DesktopIcon=Create a desktop shortcut
english.AutoStart=Start Basket automatically with Windows (recommended for the shop server)
english.LaunchApp=Launch Basket now

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"
Name: "autostart"; Description: "{cm:AutoStart}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Basket"; Filename: "{app}\basket.exe"
Name: "{autodesktop}\Basket"; Filename: "{app}\basket.exe"; Tasks: desktopicon
Name: "{commonstartup}\Basket"; Filename: "{app}\basket.exe"; Tasks: autostart

[Run]
; الـ Firewall: بنسمح للبرنامج بس (مش بورتات مفتوحة لأي حاجة) عشان الموبايلات تتصل بالسيرفر.
; profile=any لأن شبكة الواي فاي في محلات كتير Windows بيعتبرها "عامة".
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Basket"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Basket"" dir=in action=allow program=""{app}\basket.exe"" enable=yes profile=any"; Flags: runhidden waituntilterminated
Filename: "{app}\basket.exe"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Basket"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"

; بيانات المحل (في AppData) مش بتتمسح مع إلغاء التثبيت، عشان مايضيعش حاجة بالغلط.
