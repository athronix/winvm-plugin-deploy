# vm-purge-runtime.ps1 - deep runtime purge (undeploy --purge-all step 2e).
# Covers what vm-remove-local.ps1 deliberately does NOT: the Node runtimes
# (C:\nodejs + nvm store), the codebuddy global package, VM-side ~/.ssh key
# material, npm cache, dead PATH entries, leftover tasks and firewall rules.
# Does NOT touch sshd (see vm-purge-sshd.ps1: it must run deferred as SYSTEM,
# otherwise it kills the session that is executing it).
#
# -KeepWinVMDeploy : keep C:\ProgramData\WinVMDeploy. Required when the caller
#   will still run oneclick -Rollback afterwards (step 3b) - the rollback script
#   and the OpenSSH MSI cache live there. Step 3b deletes it as its last act.
#
# ASCII-only (ps-run.sh rejects any byte > 127). Idempotent: absent = SKIP.
param([switch]$Apply, [switch]$KeepWinVMDeploy)
$ErrorActionPreference = 'Continue'
$Mode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Output ('MODE=' + $Mode)
Write-Output ('KEEP_WINVMDEPLOY=' + [bool]$KeepWinVMDeploy)
function Act([string]$m) { if ($Apply) { Write-Output ('[DO]  ' + $m) } else { Write-Output ('[DRY] ' + $m) } }
function Rep([string]$k, $v) { Write-Output ($k + '=' + $v) }
function Sz([string]$p) {
  if (-not (Test-Path $p)) { return 'NA' }
  try {
    $s = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round($s / 1MB, 1)
  } catch { return 'ERR' }
}
function RmTree([string]$p, [string]$label) {
  if (-not (Test-Path $p)) { Rep ('SKIP_' + $label) 'absent'; return 0 }
  $sz = Sz $p
  Act ('Remove-Item -Recurse -Force ' + $p + ' (' + $sz + ' MB)')
  if (-not $Apply) { return 0 }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { Remove-Item $p -Recurse -Force -ErrorAction Stop } catch {
    Write-Output ('[WARN] Remove-Item failed (' + $_.Exception.Message + '), fallback rmdir')
    $null = cmd /c ('rmdir /s /q "' + $p + '" 2>nul')
  }
  $sw.Stop()
  Rep ('SEC_' + $label) ([math]::Round($sw.Elapsed.TotalSeconds, 1))
  Rep ('LEFT_' + $label) (Test-Path $p)
  return 1
}

$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$NvmDir = Join-Path $env:LOCALAPPDATA 'Author Software\nvm'

Write-Output '--- PRE ---'
Rep 'BRIDGE_DIR' (Test-Path 'C:\WinVMBridge')
Rep 'WORKSPACE_DIR' (Test-Path 'C:\WinVMWorkspace')
Rep 'NODEJS_DIR' (Test-Path 'C:\nodejs')
Rep 'NVM_DIR' (Test-Path $NvmDir)
Rep 'WINVMDEPLOY_DIR' (Test-Path 'C:\ProgramData\WinVMDeploy')
Rep 'USER_SSH_DIR' (Test-Path (Join-Path $env:USERPROFILE '.ssh'))
foreach ($c in @('node','npm','codebuddy','agent-browser','agent-desktop')) {
  $g = Get-Command $c -ErrorAction SilentlyContinue
  Rep ('CMD_' + $c.ToUpper().Replace('-','_')) $(if ($g) { $g.Source } else { 'MISSING' })
}
Rep 'SZ_NODEJS' (Sz 'C:\nodejs')
Rep 'SZ_NVM' (Sz $NvmDir)

Write-Output '--- 1) VM ~/.ssh key material ---'
$sshDir = Join-Path $env:USERPROFILE '.ssh'
if (Test-Path $sshDir) {
  $files = Get-ChildItem $sshDir -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
  Rep 'SSH_FILES_BEFORE' ($files -join ',')
  foreach ($f in @('authorized_keys','id_ed25519','id_ed25519.pub','known_hosts','known_hosts.old','config')) {
    $p = Join-Path $sshDir $f
    if (Test-Path $p) {
      Act ('remove ' + $p)
      if ($Apply) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
  }
  if ($Apply) {
    $left = Get-ChildItem $sshDir -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    Rep 'SSH_FILES_AFTER' ($(if ($left) { $left -join ',' } else { 'EMPTY' }))
  }
} else { Write-Output '[SKIP] ~/.ssh absent' }

Write-Output '--- 2) codebuddy global package ---'
$cb = Get-Command codebuddy -ErrorAction SilentlyContinue
if (-not $cb) { Write-Output '[SKIP] codebuddy not on PATH' }
else {
  Rep 'CODEBUDDY_AT' $cb.Source
  # codebuddy lives in the nvm-managed node dir, so its npm prefix differs from
  # the prefix that npm root -g reports. Resolve the package dir from the shim.
  $cbDir = Split-Path -Parent (Split-Path -Parent $cb.Source)
  Rep 'CODEBUDDY_PKG_DIR' $cbDir
  $pkgJson = Join-Path $cbDir 'node_modules\@tencent-ai\codebuddy-code\package.json'
  if (Test-Path $pkgJson) {
    Act ('remove package tree ' + (Split-Path -Parent $pkgJson))
    if ($Apply) { Remove-Item (Split-Path -Parent $pkgJson) -Recurse -Force -ErrorAction SilentlyContinue }
  }
  foreach ($shim in @('codebuddy','codebuddy.cmd','codebuddy.ps1')) {
    $sp = Join-Path $cbDir $shim
    if (Test-Path $sp) {
      Act ('remove shim ' + $sp)
      if ($Apply) { Remove-Item $sp -Force -ErrorAction SilentlyContinue }
    }
  }
}

Write-Output '--- 3) node runtimes ---'
# Order matters: remove the standalone runtime and the nvm store, then scrub PATH.
$null = RmTree 'C:\nodejs' 'DELETE_NODEJS'
$null = RmTree $NvmDir 'DELETE_NVM'
$npmCache = Join-Path $env:LOCALAPPDATA 'npm-cache'
if (Test-Path $npmCache) {
  Rep 'SZ_NPM_CACHE' (Sz $npmCache)
  Act ('remove npm cache ' + $npmCache)
  if ($Apply) { Remove-Item $npmCache -Recurse -Force -ErrorAction SilentlyContinue }
} else { Write-Output '[SKIP] npm-cache absent' }

Write-Output '--- 4) dead PATH entries ---'
$targets = @('C:\nodejs', 'Author Software\nvm', 'WinVMBridge')
foreach ($scope in @('Machine','User')) {
  $cur = [Environment]::GetEnvironmentVariable('Path', $scope)
  if (-not $cur) { continue }
  $parts = $cur.Split(';') | Where-Object { $_ -ne '' }
  $keep = @(); $drop = @()
  foreach ($p in $parts) {
    $hit = $false
    foreach ($t in $targets) { if ($p -like ('*' + $t + '*')) { $hit = $true } }
    if ($hit) { $drop += $p } else { $keep += $p }
  }
  Rep ('PATH_' + $scope + '_BEFORE') $parts.Count
  Rep ('PATH_' + $scope + '_DROP') $(if ($drop) { $drop -join ' | ' } else { 'NONE' })
  if ($drop.Count -gt 0 -and $Apply) {
    [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), $scope)
    Rep ('PATH_' + $scope + '_AFTER') $keep.Count
  }
}

Write-Output '--- 5) C:\ProgramData\WinVMDeploy (oneclick script + MSI cache) ---'
if ($KeepWinVMDeploy) {
  # Step 3b still needs winvm-sshd-oneclick.ps1 (and its MSI cache) to roll back.
  # Step 3b removes this directory as its final act.
  Rep 'KEPT_WINVMDEPLOY' (Test-Path 'C:\ProgramData\WinVMDeploy')
} else {
  $null = RmTree 'C:\ProgramData\WinVMDeploy' 'DELETE_WINVMDEPLOY'
}

Write-Output '--- 6) leftover scheduled tasks ---'
foreach ($t in @('WinVMBridge.Service','WbTunnelRollback')) {
  $null = schtasks /Query /TN $t 2> $null
  if ($LASTEXITCODE -eq 0) {
    Act ('schtasks /Delete /TN ' + $t + ' /F')
    if ($Apply) { $null = schtasks /Delete /TN $t /F 2> $null }
  } else { Write-Output ('[SKIP] task absent: ' + $t) }
}

Write-Output '--- 7) firewall rules left by the installer ---'
$fw = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'WinVM' }
foreach ($r in $fw) {
  Act ('remove firewall rule ' + $r.DisplayName + ' (' + $r.Direction + ')')
  if ($Apply) { Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
}
if (-not $fw) { Write-Output '[SKIP] no WinVM firewall rule' }

Write-Output '--- POST ---'
Rep 'BRIDGE_DIR' (Test-Path 'C:\WinVMBridge')
Rep 'WORKSPACE_DIR' (Test-Path 'C:\WinVMWorkspace')
Rep 'NODEJS_DIR' (Test-Path 'C:\nodejs')
Rep 'NVM_DIR' (Test-Path $NvmDir)
Rep 'WINVMDEPLOY_DIR' (Test-Path 'C:\ProgramData\WinVMDeploy')
Rep 'PORT_18443' ([bool](Get-NetTCPConnection -LocalPort 18443 -State Listen -ErrorAction SilentlyContinue))
$null = schtasks /Query /TN 'WinVMBridge.Service' 2> $null
Rep 'TASK_SERVICE' ($LASTEXITCODE -eq 0)
foreach ($c in @('node','npm','codebuddy','agent-browser','agent-desktop')) {
  $g = Get-Command $c -ErrorAction SilentlyContinue
  Rep ('CMD_' + $c.ToUpper().Replace('-','_')) $(if ($g) { $g.Source } else { 'MISSING' })
}
if ($Apply) { Write-Output 'PURGE_RUNTIME_DONE' }
