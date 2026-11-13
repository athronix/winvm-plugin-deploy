# vm-diag.ps1 -- read-only inspection of the WinVM sshd tunnel (no side effects)
# Companion to verify-tunnel.sh.
# NOTE: section header function is named Section, NOT H -- "h" is a built-in alias
#       for Get-History and aliases win over functions in PowerShell resolution.
# Usage (from HarmonyOS host):
#   scp vm-diag.ps1 User@172.16.100.2:Downloads/
#   ssh User@172.16.100.2 "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\Downloads\vm-diag.ps1"
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$SSHD_CFG  = 'C:\ProgramData\ssh\sshd_config'
$STATE     = 'C:\ProgramData\ssh\wb-tunnel-state.json'
$ADMIN_AK  = 'C:\ProgramData\ssh\administrators_authorized_keys'
$USER_HOME = $env:USERPROFILE

function Section([string]$t) { ''; '===== ' + $t + ' =====' }

Section 'VERSION / FILES'
foreach ($p in @($SSHD_CFG, $STATE, $ADMIN_AK, (Join-Path $USER_HOME 'Downloads\winvm-sshd-oneclick.ps1'))) {
  if (Test-Path $p) {
    $i = Get-Item $p
    '{0,-58} {1,10} bytes  {2}' -f $p, $i.Length, $i.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
  } else { '{0,-58} MISSING' -f $p }
}
$oneClick = Join-Path $USER_HOME 'Downloads\winvm-sshd-oneclick.ps1'
if (Test-Path $oneClick) {
  $v = Select-String -Path $oneClick -Pattern "SCRIPT_VERSION\s*=\s*'([^']+)'" | Select-Object -First 1
  if ($v) { 'oneclick SCRIPT_VERSION = ' + $v.Matches[0].Groups[1].Value }
}

Section 'SERVICE'
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if ($svc) {
  $w = Get-CimInstance Win32_Service -Filter "Name='sshd'"
  'sshd Status={0} StartType={1} ProcessId={2} StartName={3}' -f $svc.Status, $svc.StartType, $w.ProcessId, $w.StartName
  'binary path = ' + $w.PathName
} else { 'sshd service ABSENT' }

Section 'LISTENING 22'
$lis = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue
if ($lis) { $lis | ForEach-Object { 'listen {0}:{1} pid={2}' -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess } }
else { 'nothing listening on 22' }

Section 'EFFECTIVE SSHD CONFIG (sshd -T)'
$sshdCandidates = @()
if ($svc) {
  $w = Get-CimInstance Win32_Service -Filter "Name='sshd'"
  if ($w.PathName -match '"?([A-Za-z]:\\[^"]*sshd\.exe)') { $sshdCandidates += $matches[1] }
}
$sshdCandidates += 'C:\Program Files\OpenSSH\sshd.exe'
$sshdCandidates += 'C:\Windows\System32\OpenSSH\sshd.exe'
$sshdExe = $sshdCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($sshdExe) {
  'sshd.exe = ' + $sshdExe
  $t = & $sshdExe -T 2>&1
  $keys = 'listenaddress','passwordauthentication','permitemptypasswords','pubkeyauthentication',
          'gatewayports','allowtcpforwarding','permittunnel','maxauthtries','logingracetime',
          'authorizedkeysfile','permitrootlogin','usepam'
  foreach ($line in $t) {
    $k = ($line -split '\s+')[0].ToLower()
    if ($keys -contains $k) { '  ' + $line }
  }
} else { 'sshd.exe not found (tried service path, Program Files, System32)' }

Section 'SSHD_CONFIG (effective lines only)'
if (Test-Path $SSHD_CFG) {
  Get-Content $SSHD_CFG | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { '  ' + $_.Trim() }
}

Section 'LSA LIMITBLANKPASSWORDUSE'
$lsa = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -ErrorAction SilentlyContinue
if ($null -ne $lsa) { 'LimitBlankPasswordUse = {0}   (1 = blank-password NETWORK logon blocked / 0 = allowed)' -f $lsa.LimitBlankPasswordUse }
else { 'LimitBlankPasswordUse not set (defaults to 1)' }

Section 'FIREWALL RULES THAT COVER TCP 22'
# 管道方向是本脚本最坑的一处（2026-11-10 实测）：
#   rule | Get-NetFirewallPortFilter        -> 一条都匹配不上（静默返回空，假阴性）
#   portfilter | Get-NetFirewallAddressFilter -> AmbiguousParameterSet
#   portfilter -> Get-NetFirewallRule -Name <InstanceID> -> Get-NetFirewallAddressFilter -AssociatedNetFirewallRule  [唯一可靠]
# 注意：全量 Get-NetFirewallAddressFilter / 逐规则 pipe 都要几十秒到几分钟，别用。
# 不要用 $arr += $cimInstance 收集（PS5.1 上会报 op_Addition），直接单层循环。
$n = 0
foreach ($p in (Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
  if ([string]$p.LocalPort -ne '22') { continue }
  $nm = [string]$p.InstanceID
  $r = Get-NetFirewallRule -Name $nm -ErrorAction SilentlyContinue
  if (-not $r) { $r = $p | Get-NetFirewallRule -ErrorAction SilentlyContinue }
  if (-not $r) { '  ! port-22 filter has no resolvable rule: ' + $nm; continue }
  $a = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $r -ErrorAction SilentlyContinue
  $n++
  '[{0}] name={1}' -f $n, $r.Name
  '     display="{0}"' -f $r.DisplayName
  '     enabled={0} dir={1} action={2} profile={3} proto={4} remote={5}' -f `
     $r.Enabled, $r.Direction, $r.Action, $r.Profile, $p.Protocol, ((@($a.RemoteAddress)) -join ',')
}
if ($n -eq 0) { 'no inbound rule matches TCP 22  <-- 若 ssh 仍可连，说明本段探测失败，不要据此判断"没开"' }
'--- firewall profile defaults ---'
Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object {
  '  {0,-8} Enabled={1} InboundDefault={2}' -f $_.Name, $_.Enabled, $_.DefaultInboundAction
}

Section 'PORT PROXY (netsh)'
$pp = (netsh interface portproxy show all 2>&1) -join "`n"
if ($pp -match 'Listen on|\d+\.\d+\.\d+\.\d+\s+\d+') { $pp } else { 'none' }

Section 'NEIGHBORS ON 172.16.100.0/24'
$nb = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '172.16.100.*' }
if ($nb) { $nb | ForEach-Object { '  {0,-16} {1,-18} {2}' -f $_.IPAddress, $_.LinkLayerAddress, $_.State } }
else { 'no neighbor in 172.16.100.0/24' }
'--- own addresses in that subnet ---'
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '172.16.100.*' } |
  ForEach-Object { '  {0}/{1} ifIndex={2} ({3})' -f $_.IPAddress, $_.PrefixLength, $_.InterfaceIndex, $_.InterfaceAlias }

Section 'AUTHORIZED KEYS'
if (Test-Path $ADMIN_AK) {
  $ak = @(Get-Content $ADMIN_AK)
  'administrators_authorized_keys: {0} line(s)' -f $ak.Count
  foreach ($l in $ak) {
    if ($l -match '^(ssh-\S+|ecdsa-\S+)\s+\S+\s*(.*)$') { '  type={0} comment="{1}"' -f $matches[1], $matches[2] }
    elseif ($l -match '\S') { '  (non-standard line, {0} chars)' -f $l.Length }
  }
  '  SDDL=' + (Get-Acl $ADMIN_AK).Sddl
} else { 'administrators_authorized_keys ABSENT' }

Section 'JOURNAL (wb-tunnel-state.json)'
if (Test-Path $STATE) {
  try {
    $st = Get-Content $STATE -Raw -Encoding UTF8 | ConvertFrom-Json
    'schema={0} journalVersion={1} status={2} buildCount={3}' -f $st.schema, $st.version, $st.status, $st.buildCount
    'createdAt={0}  updatedAt={1}' -f $st.createdAt, $st.updatedAt
    $ops = @($st.ops)
    'ops total={0}' -f $ops.Count
    foreach ($o in $ops) {
      '  #{0,-2} {1,-34} undoState={2,-9} result={3}' -f $o.id, $o.action, $o.undoState, $o.result
    }
    'ops still undoable (pending) = {0}' -f @($ops | Where-Object { $_.undoState -eq 'pending' }).Count
  } catch { 'journal parse failed: ' + $_.Exception.Message }
} else { 'journal ABSENT (never built here, or already cleaned)' }

Section 'TEMP LEFTOVERS'
foreach ($dir in @($env:TEMP, (Join-Path $USER_HOME 'Downloads'), $USER_HOME, 'C:\ProgramData\ssh')) {
  foreach ($pat in @('wb-rollback.ps1','winvm-sshd-oneclick.ps1','vm-diag.ps1','wb-*.log','wb-tunnel-state.json.bak*')) {
    Get-ChildItem -Path (Join-Path $dir $pat) -ErrorAction SilentlyContinue |
      ForEach-Object { '  {0,10} bytes  {1}  {2}' -f $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.FullName }
  }
}

Section 'OPENSSH EVENT LOG (last 12 auth decisions)'
try {
  $ev = Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 80 -ErrorAction Stop
  $ev | Where-Object { $_.Message -match 'Accepted|Failed|Connection from' } |
    Select-Object -First 12 |
    ForEach-Object { '  {0}  {1}' -f $_.TimeCreated.ToString('MM-dd HH:mm:ss'), (($_.Message -split "`r?`n")[0]) }
} catch { 'OpenSSH/Operational log unavailable: ' + $_.Exception.Message }

''
'===== DIAG DONE ====='
