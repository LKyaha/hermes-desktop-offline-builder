Unicode true
RequestExecutionLevel user
SilentInstall silent
SilentUnInstall silent
AutoCloseWindow true
ShowInstDetails nevershow
CRCCheck on

!ifndef OUTFILE
  !error "OUTFILE define is required"
!endif
!ifndef BOOTSTRAP_EXE
  !error "BOOTSTRAP_EXE define is required"
!endif
!ifndef OFFLINE_SCRIPT
  !error "OFFLINE_SCRIPT define is required"
!endif
!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR define is required"
!endif
!ifndef HERMES_VERSION
  !define HERMES_VERSION "unknown"
!endif

Name "Hermes Offline Setup ${HERMES_VERSION}"
OutFile "${OUTFILE}"

# The payload files are already gzip-compressed. Re-compressing them inside the
# outer NSIS executable wastes CI time for negligible size savings.
SetCompress off

Section "Hermes Offline Setup"
  # $PLUGINSDIR is a unique per-process temporary directory and is cleaned by
  # NSIS when this wrapper exits. The user never sees a second setup wizard:
  # this wrapper only extracts, sets environment variables, and starts the
  # official Hermes Bootstrap GUI.
  InitPluginsDir

  SetOutPath "$PLUGINSDIR\bootstrap"
  File /oname=Hermes-Setup.exe "${BOOTSTRAP_EXE}"

  SetOutPath "$PLUGINSDIR\offline-root\scripts"
  File /oname=install.ps1 "${OFFLINE_SCRIPT}"

  SetOutPath "$PLUGINSDIR\payload"
  File "${PAYLOAD_DIR}\manifest.json"
  File "${PAYLOAD_DIR}\managed-runtime.tar.gz"
  File "${PAYLOAD_DIR}\uv-cache.tar.gz"
  File "${PAYLOAD_DIR}\npm-cache.tar.gz"
  File "${PAYLOAD_DIR}\ms-playwright.tar.gz"
  File "${PAYLOAD_DIR}\hermes-source.tar.gz"
  File "${PAYLOAD_DIR}\desktop-win-x64.tar.gz"

  # The official Bootstrap resolver checks HERMES_SETUP_DEV_REPO_ROOT before
  # its cache/network path. Set it only in this wrapper process; the child
  # inherits it and therefore consumes our bundled install.ps1. The second
  # variable is read by the injected offline adapter inside that script.
  System::Call 'Kernel32::SetEnvironmentVariable(t "HERMES_SETUP_DEV_REPO_ROOT", t "$PLUGINSDIR\offline-root").i'
  System::Call 'Kernel32::SetEnvironmentVariable(t "HERMES_OFFLINE_PAYLOAD", t "$PLUGINSDIR\payload").i'
  System::Call 'Kernel32::SetEnvironmentVariable(t "HERMES_OFFLINE_STRICT", t "1").i'

  ExecWait '"$PLUGINSDIR\bootstrap\Hermes-Setup.exe"' $0
  SetErrorLevel $0
SectionEnd
