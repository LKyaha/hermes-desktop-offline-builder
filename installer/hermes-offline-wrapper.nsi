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
!ifndef TRANSACTION_SCRIPT
  !define TRANSACTION_SCRIPT "${__FILEDIR__}\..\scripts\offline-transaction.ps1"
!endif
!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR define is required"
!endif
!ifndef HERMES_VERSION
  !define HERMES_VERSION "unknown"
!endif

# GitHub Actions exposes GITHUB_WORKSPACE with Windows backslashes, but the
# PowerShell build step historically appended child paths with '/', producing
# mixed paths such as D:\a\repo/offline-bundle/bootstrap/Hermes-Setup.exe.
# NSIS' compile-time File command does not reliably resolve those mixed paths.
# Normalize every compile-time input here so this wrapper is robust regardless
# of how the caller constructed the path.
!searchreplace BOOTSTRAP_EXE_WIN "${BOOTSTRAP_EXE}" "/" "\"
!searchreplace OFFLINE_SCRIPT_WIN "${OFFLINE_SCRIPT}" "/" "\"
!searchreplace TRANSACTION_SCRIPT_WIN "${TRANSACTION_SCRIPT}" "/" "\"
!searchreplace PAYLOAD_DIR_WIN "${PAYLOAD_DIR}" "/" "\"

Name "Hermes Offline Setup ${HERMES_VERSION}"
OutFile "${OUTFILE}"

# The payload files are already gzip-compressed. Re-compressing them inside the
# outer NSIS executable wastes CI time for negligible size savings.
SetCompress off

Section "Hermes Offline Setup"
  # $PLUGINSDIR is a unique per-process temporary directory and is cleaned by
  # NSIS when this wrapper exits. The user never sees a second setup wizard:
  # this wrapper only extracts, transactionally protects an existing managed
  # install, sets environment variables, and starts the official Hermes GUI.
  InitPluginsDir

  SetOutPath "$PLUGINSDIR\bootstrap"
  File /oname=Hermes-Setup.exe "${BOOTSTRAP_EXE_WIN}"

  SetOutPath "$PLUGINSDIR\offline-root\scripts"
  File /oname=install.ps1 "${OFFLINE_SCRIPT_WIN}"

  SetOutPath "$PLUGINSDIR\transaction"
  File /oname=offline-transaction.ps1 "${TRANSACTION_SCRIPT_WIN}"

  SetOutPath "$PLUGINSDIR\payload"
  File "${PAYLOAD_DIR_WIN}\manifest.json"
  File "${PAYLOAD_DIR_WIN}\managed-runtime.tar.gz"
  File "${PAYLOAD_DIR_WIN}\uv-cache.tar.gz"
  File "${PAYLOAD_DIR_WIN}\npm-cache.tar.gz"
  File "${PAYLOAD_DIR_WIN}\ms-playwright.tar.gz"
  File "${PAYLOAD_DIR_WIN}\hermes-source.tar.gz"
  File "${PAYLOAD_DIR_WIN}\desktop-win-x64.tar.gz"

  # An offline upgrade is a transaction around the ENTIRE official Bootstrap
  # lifecycle, not a permanent backup made by one repository stage. Begin uses
  # same-volume renames for the old managed installation/runtime. If Bootstrap
  # succeeds, Commit immediately removes the temporary rollback data. If it
  # fails or the user cancels, Rollback restores the old managed bytes. A stale
  # transaction from a power loss is recovered by the next Begin invocation.
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\transaction\offline-transaction.ps1" -Mode Begin' $1
  IntCmp $1 0 transaction_ready transaction_begin_failed transaction_begin_failed

transaction_begin_failed:
  MessageBox MB_OK|MB_ICONSTOP "Hermes could not prepare the existing installation for a safe offline upgrade.$\r$\n$\r$\nClose Hermes and try again. The previous installation was not intentionally removed."
  SetErrorLevel $1
  Goto transaction_done

transaction_ready:
  # The official Bootstrap resolver checks HERMES_SETUP_DEV_REPO_ROOT before
  # its cache/network path. Set it only in this wrapper process; the child
  # inherits it and therefore consumes our bundled install.ps1. The other
  # variables are read by the injected offline adapter inside that script.
  System::Call 'Kernel32::SetEnvironmentVariable(t "HERMES_SETUP_DEV_REPO_ROOT", t "$PLUGINSDIR\offline-root").i'
  System::Call 'Kernel32::SetEnvironmentVariable(t "HERMES_OFFLINE_PAYLOAD", t "$PLUGINSDIR\payload").i'
  System::Call 'Kernel32::SetEnvironmentVariable(t "HERMES_OFFLINE_STRICT", t "1").i'

  ExecWait '"$PLUGINSDIR\bootstrap\Hermes-Setup.exe"' $0
  IntCmp $0 0 bootstrap_succeeded bootstrap_failed bootstrap_failed

bootstrap_succeeded:
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\transaction\offline-transaction.ps1" -Mode Commit' $1
  IntCmp $1 0 transaction_success transaction_commit_failed transaction_commit_failed

transaction_commit_failed:
  MessageBox MB_OK|MB_ICONEXCLAMATION "Hermes installed successfully, but offline-upgrade cleanup did not finish cleanly.$\r$\n$\r$\nRe-running this installer will recover or finish the transaction safely."
  SetErrorLevel $1
  Goto transaction_done

bootstrap_failed:
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\transaction\offline-transaction.ps1" -Mode Rollback' $1
  IntCmp $1 0 rollback_finished rollback_failed rollback_failed

rollback_failed:
  MessageBox MB_OK|MB_ICONSTOP "Hermes setup failed and automatic rollback could not complete.$\r$\n$\r$\nDo not delete .hermes-offline-rollback. Re-run this installer to retry recovery."
  SetErrorLevel $0
  Goto transaction_done

rollback_finished:
  SetErrorLevel $0
  Goto transaction_done

transaction_success:
  SetErrorLevel 0

transaction_done:
SectionEnd
