param(
  [switch]$Apply,
  [switch]$PurgeWorkspace,
  [switch]$ScheduleTunnelRollback
)
# winvm-plugin-deploy v1.5.0 - VM-side LOCAL uninstaller.
# Used when the SSH channel is DOWN: the user runs this ON THE VM (Administrator
# PowerShell). It mirrors delivery/uninstall.mjs buildVmPs1() exactly, plus an
# optional POST ACTION that schedules the hos -Rollback tunnel teardown as a
# SYSTEM task so the VM executes it after the current session is gone.
# ASCII-only on purpose (ps-run.sh payload guard); never touches sshd by itself.
$ErrorActionPreference = 'Continue'
$TaskName = 'WinVMBridge.Service'
$BridgeDir = 'C:\WinVMBridge'
$WorkspaceDir = 'C:\WinVMWorkspace'
$Port = 18443
$Mode = 'DRY-RUN'
if ($Apply) { $Mode = 'APPLY' }
Write-Output ('MODE=' + $Mode)
function Act([string]$m) { if ($Apply) { Write-Output ('[DO]  ' + $m) } else { Write-Output ('[DRY] ' + $m) } }

Write-Output '--- PRE STATUS ---'
Write-Output ('BRIDGE_DIR=' + (Test-Path $BridgeDir))
Write-Output ('WORKSPACE_DIR=' + (Test-Path $WorkspaceDir))
$null = schtasks /Query /TN $TaskName 2> $null
Write-Output ('TASK_EXISTS=' + ($LASTEXITCODE -eq 0))
$l = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
Write-Output ('PORT_LISTEN=' + [bool]$l)
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
Write-Output ('SSHD=' + $(if ($sshd) { $sshd.Status } else { 'NOT_FOUND' }))

# Signature-based kill only. NEVER match node.exe by path: WorkBuddy MCP servers
# share that binary and would be killed too.
function Kill-Sig([string]$label, [string]$exe, [string]$pattern) {
  $procs = Get-CimInstance Win32_Process -Filter "Name='$exe'" -ErrorAction SilentlyContinue | Where-Object { ($_.CommandLine -match $pattern) -and ($_.ProcessId -ne $PID) }
  foreach ($p in $procs) {
    Act ('taskkill /T /F ' + $label + ' PID ' + $p.ProcessId)
    if ($Apply) { $null = taskkill /PID $p.ProcessId /T /F 2> $null }
  }
}

Write-Output '--- 0) fuse watchdog, then kill service chain ---'
$null = schtasks /Query /TN $TaskName 2> $null
if ($LASTEXITCODE -eq 0) {
  Act ('schtasks /End (fuse RestartOnFailure) ' + $TaskName)
  if ($Apply) { $null = schtasks /End /TN $TaskName 2> $null }
} else { Write-Output ('[SKIP] task not present: ' + $TaskName) }
Kill-Sig 'vm-service node' 'node.exe' ([regex]::Escape($BridgeDir))
Kill-Sig 'start-hidden wrapper' 'powershell.exe' 'start-hidden'
Kill-Sig 'ps-bridge' 'powershell.exe' 'ps-bridge'
if ($Apply) {
  Start-Sleep -Seconds 2
  $still = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($still) { Write-Output '[WARN] port still listening after service kills' }
  else { Write-Output '[OK]  services killed, port freed' }
}

Write-Output '--- 1) delete the watchdog registration ---'
$null = schtasks /Query /TN $TaskName 2> $null
if ($LASTEXITCODE -eq 0) {
  Act ('schtasks /Delete ' + $TaskName)
  if ($Apply) {
    $null = schtasks /Delete /TN $TaskName /F 2> $null
    if ($LASTEXITCODE -eq 0) { Write-Output ('[OK]  task removed: ' + $TaskName) }
    else { Write-Output ('[WARN] task delete exit=' + $LASTEXITCODE) }
  }
} else { Write-Output ('[SKIP] task already absent: ' + $TaskName) }

Write-Output '--- 2) leftover sweep (idempotent) ---'
Kill-Sig 'leftover vm-service node' 'node.exe' ([regex]::Escape($BridgeDir))
Kill-Sig 'leftover start-hidden wrapper' 'powershell.exe' 'start-hidden'
Kill-Sig 'leftover ps-bridge' 'powershell.exe' 'ps-bridge'
if ($Apply) {
  Start-Sleep -Seconds 2
  $still2 = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($still2) { Write-Output '[WARN] port still listening after leftover sweep' }
  else { Write-Output '[OK]  port freed (final)' }
}

Write-Output '--- 3) remove C:\WinVMBridge ---'
if (Test-Path $BridgeDir) {
  Act ('Remove-Item -Recurse -Force ' + $BridgeDir)
  if ($Apply) { Remove-Item $BridgeDir -Recurse -Force }
} else { Write-Output '[SKIP] C:\WinVMBridge not present' }

Write-Output '--- 4) workspace (kept by default) ---'
if ($PurgeWorkspace) {
  if (Test-Path $WorkspaceDir) {
    Act ('Remove-Item -Recurse -Force ' + $WorkspaceDir + ' (-PurgeWorkspace)')
    if ($Apply) { Remove-Item $WorkspaceDir -Recurse -Force }
  } else { Write-Output '[SKIP] C:\WinVMWorkspace not present' }
} else { Write-Output ('[KEEP] workspace kept by default: ' + $WorkspaceDir) }

Write-Output '--- 5) agent skill junctions into shared-skills ---'
$skillRoots = @((Join-Path $env:USERPROFILE '.workbuddy\skills'), (Join-Path $env:USERPROFILE '.hermes\skills'))
foreach ($r in $skillRoots) {
  if (-not (Test-Path $r)) { continue }
  Get-ChildItem $r -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -and $_.Target -like ($BridgeDir + '*') } | ForEach-Object {
    Act ('remove junction ' + $_.FullName)
    if ($Apply) { [System.IO.Directory]::Delete($_.FullName, $false) }
  }
}

Write-Output '--- 6) VM user PATH entry ---'
$deadPath = 'C:\WinVMBridge\delivery'
$up = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($up -and ($up -like ('*' + $deadPath + '*'))) {
  Act ('remove VM user PATH entry ' + $deadPath)
  if ($Apply) {
    $parts = $up.Split(';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $deadPath) }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
  }
} else { Write-Output '[SKIP] VM user PATH has no WinVMBridge entry' }

Write-Output '--- 7) VM side.json marker ---'
$side = Join-Path $env:USERPROFILE '.workbuddy\winvm\side.json'
if (Test-Path $side) {
  Act ('remove ' + $side)
  if ($Apply) { Remove-Item $side -Force }
} else { Write-Output '[SKIP] VM side.json not present' }

# ---------- 8) OPTIONAL POST ACTION: tunnel rollback on the VM itself ----------
# The hos template -Rollback removes the authorized key / sshd_config / firewall,
# which kills this very session. Scheduling it as a SYSTEM task lets the VM finish
# the teardown on its own. Same mechanism as hos destroy-tunnel.sh.
if ($ScheduleTunnelRollback) {
  $here = Split-Path -Parent $MyInvocation.MyCommand.Path
  $rb = Join-Path $here 'wb-rollback.ps1'
  if (Test-Path $rb) {
    $tr = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $rb + ' -Rollback'
    $a1 = @('/Create','/TN','WbTunnelRollback','/TR',$tr,'/SC','ONCE','/ST','00:00','/RL','HIGHEST','/RU','SYSTEM','/F')
    Act 'schtasks /Create + /Run WbTunnelRollback (SYSTEM post action)'
    if ($Apply) {
      & schtasks.exe $a1
      & schtasks.exe @('/Run','/TN','WbTunnelRollback')
      Write-Output 'POST_ROLLBACK_SCHEDULED'
    }
  } else { Write-Output '[SKIP] wb-rollback.ps1 not beside this script; tunnel rollback not scheduled' }
}

Write-Output '--- POST STATUS ---'
Write-Output ('BRIDGE_DIR=' + (Test-Path $BridgeDir))
Write-Output ('WORKSPACE_DIR=' + (Test-Path $WorkspaceDir))
$null = schtasks /Query /TN $TaskName 2> $null
Write-Output ('TASK_EXISTS=' + ($LASTEXITCODE -eq 0))
$l2 = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
Write-Output ('PORT_LISTEN=' + [bool]$l2)
$leftNodes = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match [regex]::Escape($BridgeDir) }
Write-Output ('BRIDGE_NODE_LEFT=' + [bool]$leftNodes)
$sshd2 = Get-Service sshd -ErrorAction SilentlyContinue
Write-Output ('SSHD=' + $(if ($sshd2) { $sshd2.Status } else { 'NOT_FOUND' }))
if ($Apply) { Write-Output 'VM_CLEANUP_DONE' }
