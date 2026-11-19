# winvm-plugin-deploy - node zip fallback (DB-3 rescue path, P13)
#
# WHY THIS FILE EXISTS
#   prepare-vm's DB-3 tries winget, then a npmmirror zip download. On the real VM
#   (2026-11-19) that zip download failed ONCE with "no such host is known" while
#   DNS/proxy/TCP-443 were all healthy -- a transient mirror glitch. prepare-vm
#   writes "[DB-3][MANUAL] zip install FAILED" and still exits rc=0, so 4a looked
#   green and the fault only surfaced at 4b as VM_START_FAILED. This script is the
#   bounded rescue: it retries the download and installs node WITHOUT ever deleting
#   a directory that a running process may still hold open.
#
# CONTRACT
#   * pure ASCII, no BOM  (ps-run.sh rejects non-ASCII payloads; -File decodes ANSI)
#   * the $ver line below carries a VERSION PLACEHOLDER token that deploy-4-vm.sh
#     substitutes before pushing. Keep the token OUT of comments: a comment copy
#     placed above the real line silently eats a single-shot replace and leaves the
#     script building a 404 URL (measured 2026-11-19).
#   * idempotent: node already present => [SKIP], exit 0
#   * never rmtree $dst: a live node.exe inside it is undeletable (P11 zombie image);
#     we stage under a unique dir and copy over instead.
$ErrorActionPreference = 'Stop'

$ver = '__NODE_ZIP_VER__'
$zipUrl = 'https://cdn.npmmirror.com/binaries/node/v' + $ver + '/node-v' + $ver + '-win-x64.zip'
$dst = Join-Path $env:LOCALAPPDATA 'nodejs'
$stage = $dst + '-stage-' + $PID
$tmp = Join-Path $env:TEMP ('node-fb-' + $PID + '.zip')

if ($ver.StartsWith('__')) {
  Write-Output ('[FB] GIVEUP version placeholder not substituted (ver=' + $ver + ')')
  exit 1
}

# SSH sessions only inherit the Machine PATH segment; join User too or Get-Command misses.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

if (Get-Command node -ErrorAction SilentlyContinue) {
  Write-Output ('[FB] node present ' + (node -v) + ' [SKIP]')
  exit 0
}

Write-Output ('[FB] node missing; download node v' + $ver + ' from npmmirror (user scope)')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ok = $false
for ($i = 1; $i -le 3; $i++) {
  try {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    Invoke-WebRequest -Uri $zipUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 600
    Write-Output ('[FB] download OK attempt=' + $i + ' bytes=' + (Get-Item $tmp).Length)
    $ok = $true
    break
  } catch {
    Write-Output ('[FB] download FAIL attempt=' + $i + ' :: ' + $_.Exception.Message)
    if ($i -lt 3) { Start-Sleep -Seconds 5 }
  }
}
if (-not $ok) { Write-Output '[FB] GIVEUP download after 3 attempts'; exit 1 }

# Unpack into a per-process staging dir so a stale/locked $dst never blocks us.
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
try {
  Expand-Archive -Path $tmp -DestinationPath $stage -Force
} catch {
  Write-Output ('[FB] expand FAIL :: ' + $_.Exception.Message)
  exit 1
}
$inner = Get-ChildItem $stage -Directory | Select-Object -First 1
if (-not $inner) { Write-Output '[FB] GIVEUP zip has no top-level dir'; exit 1 }

New-Item -ItemType Directory -Path $dst -Force | Out-Null
# Per-file copy that TOLERATES a locked image.
# Measured 2026-11-19: Copy-Item -Recurse fails outright when node.exe inside $dst is
# executing (an image that is mapped cannot be overwritten either, not just deleted).
# But "node is missing from PATH" does NOT always mean "$dst is empty" -- PATH can be
# trimmed while a service still runs the exe. So: copy what we can, skip what is locked,
# and let the final Get-Command decide. If node.exe itself was the locked one and is not
# on PATH, we report RESCUE_NEEDS_IDLE and exit non-zero with an actionable message
# instead of dumping a raw IOException stack.
$copied = 0; $skipped = @()
$srcRoot = $inner.FullName
foreach ($f in (Get-ChildItem $srcRoot -Recurse -File -ErrorAction SilentlyContinue)) {
  $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
  $tgt = Join-Path $dst $rel
  $tdir = Split-Path $tgt -Parent
  if (-not (Test-Path $tdir)) { New-Item -ItemType Directory -Path $tdir -Force -ErrorAction SilentlyContinue | Out-Null }
  try { Copy-Item -LiteralPath $f.FullName -Destination $tgt -Force -ErrorAction Stop; $copied++ }
  catch { $skipped += $rel }
}
Write-Output ('[FB] copied=' + $copied + ' skipped=' + $skipped.Count)
if ($skipped.Count -gt 0) {
  Write-Output ('[FB] SKIPPED(locked): ' + (($skipped | Select-Object -First 6) -join ','))
}
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

$up = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($up -split ';') -notcontains $dst) {
  [Environment]::SetEnvironmentVariable('Path', ($up + ';' + $dst), 'User')
  Write-Output ('[FB] PATH user scope += ' + $dst)
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

if (Get-Command node -ErrorAction SilentlyContinue) {
  Write-Output ('[FB] node OK ' + (node -v))
  exit 0
}
# Not usable yet: the usual cause is that node.exe is the locked image AND the running
# process is not the one we want (or PATH still points elsewhere).
if ($skipped -contains 'node.exe') {
  Write-Output '[FB] RESCUE_NEEDS_IDLE node.exe is mapped by a running process'
  Write-Output '[FB] FIX: stop the service that runs it (schtasks /end /tn WinVMBridge.Service'
  Write-Output '     then terminate the node pid), re-run 4a; or reboot the VM (only with approval)'
  exit 2
}
Write-Output '[FB] node STILL MISSING after install'
exit 1