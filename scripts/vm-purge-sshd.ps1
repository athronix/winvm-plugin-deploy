# vm-purge-sshd.ps1 - remove sshd itself (undeploy --purge-all, runs as SYSTEM
# inside the step-3b scheduled task, AFTER the host session is already gone).
#
# Why deferred: stopping sshd kills the very session that would be running this,
# so it must never be invoked inline over the channel it is about to destroy.
#
# Removes: the sshd service, the OpenSSH MSI (product code resolved from the
# registry, not hard-coded), C:\Program Files\OpenSSH, C:\ProgramData\ssh
# (config + administrators_authorized_keys), System32\OpenSSH, firewall rules,
# and finally C:\ProgramData\WinVMDeploy (rollback script + MSI cache).
#
# Post-mortem evidence: everything is appended to C:\ProgramData\winvm-purge-sshd.log
# because the channel dies mid-way; that file survives and is readable once sshd
# is reinstalled.
#
# ASCII-only. Idempotent: every phase guards on existence.
param([switch]$Apply)
$ErrorActionPreference = 'Continue'
$Log = 'C:\ProgramData\winvm-purge-sshd.log'
function L([string]$m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m
  Write-Output $line
  try { Add-Content -Path $Log -Value $line -Encoding ASCII } catch { }
}
L ('START purge-sshd apply=' + [bool]$Apply)
if (-not $Apply) {
  L 'DRY-RUN only: no change made'
  L 'DONE purge-sshd'
  exit 0
}
# Give the caller a moment to return its output before the session dies.
Start-Sleep -Seconds 3

$sw = [Diagnostics.Stopwatch]::StartNew()

# ---- 1) resolve the OpenSSH product code BEFORE uninstalling anything ----
$guid = ''
try {
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $hit = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'OpenSSH' } | Select-Object -First 1
  if ($hit) { $guid = $hit.PSChildName; L ('STEP msi-product ' + $hit.DisplayName + ' ' + $guid) }
} catch { L ('STEP msi-product warn ' + $_.Exception.Message) }
if (-not $guid) { L 'STEP msi-product NOT_FOUND (skipping msiexec, will delete tree)' }

# ---- 2) stop + delete the service ----
L 'STEP stop-service begin'
try { Stop-Service sshd -Force -ErrorAction Stop; L 'STEP stop-service ok' }
catch { L ('STEP stop-service warn ' + $_.Exception.Message) }
L 'STEP sc-delete begin'
$null = sc.exe delete sshd 2>&1 | ForEach-Object { L ('  sc: ' + $_) }
L 'STEP sc-delete done'

# ---- 3) uninstall the MSI ----
if ($guid) {
  L ('STEP msiexec-uninstall begin ' + $guid)
  $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/X' + $guid, '/qn', '/norestart') -Wait -PassThru
  L ('STEP msiexec-uninstall exit=' + $p.ExitCode)
}

# ---- 4) remove program trees, config and key material ----
foreach ($dir in @('C:\Program Files\OpenSSH', 'C:\ProgramData\ssh', 'C:\Windows\System32\OpenSSH')) {
  if (Test-Path $dir) {
    L ('STEP remove ' + $dir)
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $dir) {
      $null = cmd /c ('rmdir /s /q "' + $dir + '" 2>nul')
      L ('  after-rmdir exists=' + (Test-Path $dir))
    }
  } else { L ('SKIP absent ' + $dir) }
}

# ---- 5) firewall rules created by the oneclick installer ----
$fw = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'OpenSSH|sshd' }
foreach ($r in $fw) {
  L ('STEP remove firewall ' + $r.DisplayName)
  Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
}

# ---- 6) WinVMDeploy (rollback script + MSI cache), last: nothing needs it now ----
if (Test-Path 'C:\ProgramData\WinVMDeploy') {
  L 'STEP remove C:\ProgramData\WinVMDeploy'
  Remove-Item 'C:\ProgramData\WinVMDeploy' -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path 'C:\ProgramData\WinVMDeploy') { $null = cmd /c 'rmdir /s /q "C:\ProgramData\WinVMDeploy" 2>nul' }
}
L ('FINAL winvmdeploy_dir=' + (Test-Path 'C:\ProgramData\WinVMDeploy'))

$svc = Get-Service sshd -ErrorAction SilentlyContinue
L ('FINAL service=' + $(if ($svc) { $svc.Status } else { 'NOT_FOUND' }))
L ('FINAL program_dir=' + (Test-Path 'C:\Program Files\OpenSSH'))
L ('FINAL data_dir=' + (Test-Path 'C:\ProgramData\ssh'))
L ('FINAL admin_keys=' + (Test-Path 'C:\ProgramData\ssh\administrators_authorized_keys'))
L ('FINAL user_keys=' + (Test-Path (Join-Path $env:USERPROFILE '.ssh\authorized_keys')))
L ('FINAL port22=' + [bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue))
$sw.Stop()
L ('SEC_TOTAL=' + [math]::Round($sw.Elapsed.TotalSeconds, 1))
L 'DONE purge-sshd'
