param(
  [switch]$Apply,
  [switch]$PurgeWorkspace,
  [switch]$KeepUpstreams,
  [switch]$ScheduleTunnelRollback
)
# winvm-plugin-deploy v2.5.6 - VM-side LOCAL uninstaller.
# Used when the SSH channel is DOWN: the user runs this ON THE VM (Administrator
# PowerShell). It mirrors delivery/uninstall.mjs buildVmPs1() exactly, plus an
# optional POST ACTION that schedules the hos -Rollback tunnel teardown as a
# SYSTEM task so the VM executes it after the current session is gone.
# ASCII-only on purpose (ps-run.sh payload guard); never touches sshd by itself.
$ErrorActionPreference = 'Continue'
# SSH sessions (Windows OpenSSH -> cmd.exe/powershell) get the bare machine PATH only:
# C:\nodejs (where npm/node and the upstream CLIs live) is a USER path entry on this VM.
# Without this fix `Get-Command npm` returns nothing and the upstream cleanup silently
# degrades to a warning (2026-11-17 real-machine finding).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
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

# ---------- pid-based precise kill (plan B) ----------
# The startup side writes the REAL pids into <deploy root>\run\*.pid:
#   service.pid   = node running vm-service     (written by start-hidden.ps1)
#   ps-bridge.pid = powershell running ps-bridge.ps1 (written by the node side)
# File format = 2 lines: <pid> then <StartTime ISO-8601 UTC>.
# Why: the signature sweep below must enumerate EVERY process and match on command
# line - slow, and it can kill unrelated processes carrying a similar command line.
# The pid file turns "guess" into "lookup". It is a FAST PATH, not a replacement:
# the signature sweep stays as the safety net for pids we never got to record.
#
# PID REUSE GUARD (mandatory): Windows recycles pids, so a stale pid file may point
# at a brand new unrelated process. We therefore verify BOTH process name and
# StartTime (2s tolerance for clock/roundtrip precision) before killing anything.
$RunDirs = @((Join-Path $BridgeDir "repo\run"), (Join-Path $BridgeDir "run"))
function Kill-PidFile([string]$label, [string]$fileName, [string]$exeName) {
  $file = $null
  foreach ($d in $RunDirs) {
    $c = Join-Path $d $fileName
    if (Test-Path -LiteralPath $c) { $file = $c; break }
  }
  if (-not $file) { Write-Output ("[SKIP] no pid file: " + $label); return }
  $raw = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)
  if ($raw.Count -lt 1) { Write-Output ("[WARN] empty pid file: " + $label); return }
  $procId = 0
  if (-not [int]::TryParse(([string]$raw[0]).Trim(), [ref]$procId)) {
    Write-Output ("[WARN] unparsable pid file: " + $label); return
  }
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $p) {
    Write-Output ("[SKIP] pid " + $procId + " already gone: " + $label + " (stale pid file, harmless)")
    return
  }
  if ($p.ProcessName -and ($p.ProcessName + ".exe") -ne $exeName) {
    Write-Output ("[SKIP] pid " + $procId + " is now " + $p.ProcessName + ", not " + $exeName + ": " + $label + " (pid reuse guard)")
    return
  }
  if ($raw.Count -ge 2 -and (([string]$raw[1]).Trim() -ne "")) {
    $want = [datetime]::MinValue
    $parsed = [datetime]::TryParse(([string]$raw[1]).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$want)
    if ($parsed) {
      try {
        $delta = [math]::Abs(($p.StartTime.ToUniversalTime() - $want.ToUniversalTime()).TotalSeconds)
        if ($delta -gt 2) {
          Write-Output ("[SKIP] pid " + $procId + " start time differs by " + [int]$delta + "s: " + $label + " (pid reuse guard)")
          return
        }
      } catch {
        Write-Output ("[WARN] cannot read StartTime for pid " + $procId + ": " + $label + " (name matched, proceeding)")
      }
    }
  }
  Act ("taskkill /T /F " + $label + " PID " + $procId + " (from pid file)")
  if ($Apply) { $null = taskkill /PID $procId /T /F 2> $null }
  if ($Apply) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

Write-Output '--- 0) fuse watchdog, then kill service chain ---'
$null = schtasks /Query /TN $TaskName 2> $null
if ($LASTEXITCODE -eq 0) {
  Act ('schtasks /End (fuse RestartOnFailure) ' + $TaskName)
  if ($Apply) { $null = schtasks /End /TN $TaskName 2> $null }
} else { Write-Output ('[SKIP] task not present: ' + $TaskName) }
# pid file first (fast + precise), signature sweep after (safety net for unrecorded pids).
Kill-PidFile 'service node (pid file)' 'service.pid' 'node.exe'
Kill-PidFile 'ps-bridge (pid file)' 'ps-bridge.pid' 'powershell.exe'
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
# Retries the pid files too: a straggler that ignored the first taskkill (or was
# re-spawned by RestartOnFailure inside the /Delete window) is caught here.
Kill-PidFile 'leftover service node (pid file)' 'service.pid' 'node.exe'
Kill-PidFile 'leftover ps-bridge (pid file)' 'ps-bridge.pid' 'powershell.exe'
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
# The historical failure mode: Remove-Item -Recurse -Force reports NOTHING and leaves
# an empty skeleton behind when some process still holds the directory as its cwd.
# With $ErrorActionPreference = Continue that failure is silent - the log says the
# step ran, the directory is still there, and the next deploy inherits the wreck.
# Now the outcome is ASSERTED (still present => loud [FAIL], never silent).
if (Test-Path $BridgeDir) {
  Act ('Remove-Item -Recurse -Force ' + $BridgeDir)
  if ($Apply) {
    try { Remove-Item $BridgeDir -Recurse -Force -ErrorAction Stop }
    catch { Write-Output ('[WARN] Remove-Item raised: ' + $_.Exception.Message) }
    Start-Sleep -Milliseconds 300
    if (Test-Path $BridgeDir) {
      Write-Output '[FAIL] C:\WinVMBridge still present after Remove-Item - something holds it (cwd / open handle)'
      $holders = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match [regex]::Escape($BridgeDir) }
      foreach ($h in $holders) { Write-Output ('BRIDGE_HOLDER PID=' + $h.ProcessId + ' NAME=' + $h.Name) }
      $leftItems = @(Get-ChildItem -LiteralPath $BridgeDir -Recurse -Force -ErrorAction SilentlyContinue)
      Write-Output ('BRIDGE_RESIDUE_ITEMS=' + $leftItems.Count)
    } else {
      Write-Output '[OK]  C:\WinVMBridge removed'
    }
  }
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

# ---------- 8) MCP upstream CLIs (agent-browser / agent-desktop) ----------
# These are installed by install-vm.mjs [4b/6] as GLOBAL npm packages and proxied by
# vm-service as /mcp/browser and /mcp/desktop. Uninstalling the plugin leaves them
# orphaned (nothing else on this VM uses them), so they are removed by default;
# -KeepUpstreams opts out.
# Two steps: (a) kill orphan upstream processes - children of the killed vm-service
# may outlive it (headed Chromium, agent-desktop daemons); (b) npm uninstall -g.
Write-Output '--- 8) MCP upstream CLIs (agent-browser / agent-desktop) ---'
$UpPkgs = @('agent-browser', 'agent-desktop')

function Kill-UpstreamProc {
  $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -and (
      ($_.CommandLine -match 'agent-desktop') -or
      ($_.CommandLine -match 'agent-browser') -or
      ($_.CommandLine -match 'ms-playwright')
    )
  }
  if (-not $procs) { Write-Output '[SKIP] no orphan upstream process'; return }
  foreach ($p in $procs) {
    Act ('taskkill /T /F ' + $p.Name + ' PID ' + $p.ProcessId)
    if ($Apply) { $null = taskkill /PID $p.ProcessId /T /F 2> $null }
  }
}
Kill-UpstreamProc

if ($KeepUpstreams) {
  Write-Output '[KEEP] upstream CLIs kept (-KeepUpstreams)'
} elseif (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
  Write-Output '[WARN] npm not found on PATH; upstream CLIs left in place'
} else {
  foreach ($pkg in $UpPkgs) {
    if (-not (Get-Command $pkg -ErrorAction SilentlyContinue)) {
      Write-Output ('[SKIP] ' + $pkg + ' not installed')
      continue
    }
    Act ('npm uninstall -g ' + $pkg)
    if ($Apply) {
      & npm uninstall -g $pkg --no-fund --no-audit 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { Write-Output ('[OK]  npm uninstall -g ' + $pkg) }
      else { Write-Output ('[WARN] npm uninstall -g ' + $pkg + ' exit=' + $LASTEXITCODE) }
    }
  }
}
$leftUp = @()
foreach ($pkg in $UpPkgs) {
  if (Get-Command $pkg -ErrorAction SilentlyContinue) { $leftUp += $pkg }
}
$leftUpTxt = if ($leftUp.Count -eq 0) { 'NONE' } else { $leftUp -join ',' }
Write-Output ('UPSTREAM_LEFT=' + $leftUpTxt)

# ---------- 9) OPTIONAL POST ACTION: tunnel rollback on the VM itself ----------
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
$leftUp2 = @()
foreach ($pkg in $UpPkgs) {
  if (Get-Command $pkg -ErrorAction SilentlyContinue) { $leftUp2 += $pkg }
}
Write-Output ('UPSTREAM_LEFT=' + $(if ($leftUp2.Count -eq 0) { 'NONE' } else { $leftUp2 -join ',' }))
$sshd2 = Get-Service sshd -ErrorAction SilentlyContinue
Write-Output ('SSHD=' + $(if ($sshd2) { $sshd2.Status } else { 'NOT_FOUND' }))
if ($Apply) { Write-Output 'VM_CLEANUP_DONE' }
