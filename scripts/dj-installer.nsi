; DJ 3.3.0 — Windows installer (NSIS).
; Built with the native Linux makensis because electron-builder's
; NSIS step needs wine32, which this VM cannot install (its i386
; package index is broken). Behaviour mirrors electron-builder's
; oneClick per-user install: no admin rights, no prompts, installs to
; %LOCALAPPDATA%\Programs\DJ, Start menu + Desktop shortcuts, and an
; uninstaller. The app's own data (index, folders, settings) lives in
; %APPDATA%\DJ and is never touched by install, update or uninstall.
;
; Usage: makensis scripts/dj-installer.nsi   (run from ~/workspace/dj-app)
; Output: release/DJ Setup 3.3.0.exe
; Paths below are relative to this script's folder (scripts/).

!define APP_NAME "DJ"
!define APP_VERSION "3.3.0"
!define APP_ID "com.dhanunjay.dj"
!define INSTALL_DIR "$LOCALAPPDATA\Programs\DJ"
!define SRC_DIR "../release/win-unpacked"

Name "${APP_NAME} ${APP_VERSION}"
OutFile "../release/DJ Setup ${APP_VERSION}.exe"
InstallDir "${INSTALL_DIR}"
Icon "../assets/icon.ico"
UninstallIcon "../assets/icon.ico"
RequestExecutionLevel user
SetCompressor lzma
ShowInstDetails nevershow
ShowUninstDetails nevershow

; One click: no pages, no questions.
Page instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  ; Everything from the unpacked app: DJ.exe, resources/app.asar,
  ; resources/app-update.yml (auto-update feed) and the bundled
  ; embedding model in resources/models/.
  File /r "${SRC_DIR}/*.*"
  ; Icon for the shortcuts (the exe itself has no embedded icon —
  ; rcedit needs wine32, which this VM cannot install).
  File /oname=DJ.ico "../assets/icon.ico"
  ; Uninstaller.
  WriteUninstaller "$INSTDIR\Uninstall DJ.exe"

  ; Start menu + Desktop shortcuts.
  CreateDirectory "$SMPROGRAMS\DJ"
  CreateShortcut "$SMPROGRAMS\DJ\DJ.lnk" "$INSTDIR\DJ.exe" "" "$INSTDIR\DJ.ico"
  CreateShortcut "$DESKTOP\DJ.lnk" "$INSTDIR\DJ.exe" "" "$INSTDIR\DJ.ico"

  ; Add/Remove Programs entry.
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "Publisher" "Dhanunjay"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "UninstallString" "$INSTDIR\Uninstall DJ.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "DisplayIcon" "$INSTDIR\DJ.ico"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
    "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$SMPROGRAMS\DJ\DJ.lnk"
  RMDir "$SMPROGRAMS\DJ"
  Delete "$DESKTOP\DJ.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
  ; Remove the app files. User data in %APPDATA%\DJ is left alone
  ; on purpose — uninstalling must never delete his index or settings.
  RMDir /r "$INSTDIR"
SectionEnd
