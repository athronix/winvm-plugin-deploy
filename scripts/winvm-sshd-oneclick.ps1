#requires -Version 5.1
<#
  hos-winvm-ssh-tunnel / Windows 侧「一次性」配置脚本

  用途：把本脚本整段粘到 Windows VM 的【管理员】PowerShell 里执行一次，即可完成
        安装 OpenSSH Server → 启动并自启 → 配置 sshd_config（含安全基线）→ 写入公钥 → ACL
        → 网络配置档（Public 自动改 Private）→ 防火墙（Profile Any）→ 重启 → 自检。

  安装来源（全自动，按顺序回退，全部走网络；不需要任何 ISO/离线介质）：
    1) 【默认首选】下载官方 MSI（github releases 的 OpenSSH-Win64-v*.msi）→ msiexec /qn 静默安装
       —— 10MB 左右，通常 10-30 秒装完；内置 GitHub 直连 + 多个加速镜像轮询
    2) 下载官方 ZIP（OpenSSH-Win64.zip）→ 解压 → Install-sshd.ps1 注册服务
    3) winget（Microsoft.OpenSSH.Preview / Beta）
    4) Windows 可选功能 Add-WindowsCapability —— 【默认不再自动尝试】
       它走 Windows Update，国内常年卡在 2/9 转圈（实测停在这里）；只有显式
       -InstallMethod Capability 才会用。注意 dism /online /add-capability 与之同源，一样慢。
    本地已有安装包时：-MsiPath C:\x\OpenSSH-Win64-v10.4.0.0.msi 或 -OpenSSHZipPath C:\x\OpenSSH-Win64.zip
    全失败时会提示手动下载路径，不会静默失败。

  变更原则：**最小必要**，只做"建通道必须的那几步"，其余保持环境原状。
    · 监听范围：只绑内网网卡 + 127.0.0.1（ListenAddress），不监听 0.0.0.0 -> 公网/Tailscale 直连不到
    · 来源限制：-AllowFrom <宿主机IP> 让防火墙只放行该来源（+ 回环）；并自动探测"其它能绕过限制的放行规则"
    · 密码认证：**默认保留 PasswordAuthentication yes**（用户可用密码登录，无论账户有无密码）
               想关闭攻击面再加 -Harden（会写 PasswordAuthentication no / MaxAuthTries 3 / LoginGraceTime 30）
    · 空密码：默认 PermitEmptyPasswords no —— 这是**安全底线**，不是可选项。
       ⚠ 为什么不能放开（2026-11-10 实测踩到）：OpenSSH 的 auth2-none.c 规定
         「账户密码为空 且 permit_empty_passwd=yes」时 **none 认证直接成功**；
         而 ssh 客户端总是**先发 none 认证**。所以一旦放开，所有登录都变成
         `Accepted none`（无凭据匿名登录），公钥永远不会被使用 —— "免密通道"
         实际变成"匿名通道"，且表面看起来完全正常（能连、能执行命令），极难发现。
       结论：空密码账户只能走公钥（公钥认证不核对密码）。这正是本 skill 的用途。
       -EmptyPasswordMode auto（默认）= 探测账户有无密码，仅用于打印结论，**不改变** PermitEmptyPasswords
       -EmptyPasswordMode no   = 强制禁止（与 auto 等效，跳过探测）
       -EmptyPasswordMode yes  = 显式放开空密码密码登录；**代价是同时打开 none 匿名登录**，
                                 脚本打大红警告，且 build 自检会直接判 FAIL。
    注意：本脚本绝不修改账户密码。唯一可能改的注册表值是
          HKLM\SYSTEM\CurrentControlSet\Control\Lsa\LimitBlankPasswordUse（仅 yes 模式下），
          改动会进 journal，destroy 时按记录精确还原（没改过就不碰）。

  三种运行模式（互斥，可组合 -Rollback -Continue）：
    默认（无开关）  build    ：构建通道（可重复执行，幂等；每次写入 journal）
    -Continue       diagnose ：只读体检，不动系统；给出"能不能连上"的判定 + 报告文件
    -Rollback       destroy  ：按 journal 逆序撤销，精确还原（幂等，可重复执行）

  参数示例：
    -Port 2222            非标端口（sshd_config 与防火墙同步）
    -ListenAddress auto   仅监听内网网卡 + 127.0.0.1（推荐；auto=自动探测，也可直接给 IP，all=不限制）
    -AllowFrom 172.16.100.1   防火墙只放行该来源（可逗号分隔多个）；不传=不限来源
    -Harden               显式收紧（关密码认证 + MaxAuthTries 3 + LoginGraceTime 30）；默认**不**收紧
    -EmptyPasswordMode auto|yes|no  空密码策略；auto(默认)=只探测不放开（PermitEmptyPasswords no）
                                    yes = 放开空密码密码登录，**同时打开 none 匿名登录**（危险）
    -AllowEmptyPassword   旧写法，等同 -EmptyPasswordMode yes
    -NoHarden             兼容保留（默认已不收紧，此开关无作用）
    -DryRun               预演：不安装、不写文件、不重启、不写公钥（只打印计划）
    -Rollback -DryRun     只打印回滚计划，不动任何东西
    -Continue             只读体检（服务/监听/网络档/防火墙/授权文件/事件日志/journal）
    -KeepService          回滚时保留 sshd 服务与程序，只撤配置/公钥/防火墙/网络
    -InstallMethod Msi    指定安装方式：Auto(默认 Msi->Zip->Winget) / Msi / Zip / Dism / Winget / Capability
    -DownloadUrl <url>    自定义下载源（.msi 或 .zip 完整 URL），优先于内置镜像；不指定 InstallMethod 时按扩展名推断
    -ProxyUrl <url>       走代理下载，如 http://127.0.0.1:2080（HEAD 探测、下载、GitHub API 都会用）
    -MsiPath C:\x\OpenSSH-Win64-v10.4.0.0.msi  已手动下载 msi 时直接用（跳过下载）
    -OpenSSHZipPath C:\x\OpenSSH-Win64.zip     已手动下载 zip 时直接用（跳过下载）
    -SkipInstall          已确认装好，跳过安装阶段

  可逆性（journal v2）：
    C:\ProgramData\ssh\wb-tunnel-state.json 记录：
      · params     本次调用的全部参数 + 公钥 sha256/注释（不含任何密码）
      · env        主机名 / OS / PowerShell 版本 / 是否管理员 / 脚本版本与哈希
      · baseline   构建前状态快照（首次采集后不再覆盖）：服务、能力、配置、网络档、防火墙、
                   授权文件（含 ACL 的 SDDL）、账户策略
      · ops[]      每个写操作一条：{id,stage,action,before,after,result,undo,undoState,undoTs,undoResult}
      · rollbacks[] 每次回滚的汇总：{ts,dryRun,total,done,skipped,kept,failed,notes}
    · 回滚 = 逆序执行 undo；已 done 的自动跳过（幂等）；逐条落盘（中断可续跑）；
      全部成功才把 status 置 rolledback；下次 build 会把旧账本归档后重开。
    · ACL 用 SDDL 精确还原（原 ACL 不再"只能记不能还"）。

  日志（全部落在 C:\ProgramData\ssh\，出错可直接整段复制回来）：
    wb-tunnel-build-<ts>.log     构建全过程
    wb-tunnel-rollback-<ts>.log  回滚全过程（含每条 undo 的结果）
    wb-tunnel-diag-<ts>.log      -Continue 体检
    wb-tunnel-error-<ts>.log     失败现场（异常 + 堆栈 + 尾日志 + journal）
#>
[CmdletBinding()]
param(
  [string]$PublicKey = '__PUBKEY__',
  [string]$User      = $env:USERNAME,
  [int]   $Port      = 22,
  [switch]$Rollback,
  [Alias('Continue')][switch]$ContinueMode,
  [switch]$KeepService,
  [switch]$NoHarden,           # 兼容保留（默认已不收紧，此开关为 no-op）
  [switch]$Harden,             # 显式收紧：关闭密码认证 + MaxAuthTries 3 + LoginGraceTime 30
  [switch]$AllowEmptyPassword, # 旧写法；等同 -EmptyPasswordMode yes
  [ValidateSet('auto','yes','no')][string]$EmptyPasswordMode = 'auto',  # 空密码策略：auto=跟随 $User 真实状态
  [string]$ListenAddress = 'auto',  # 仅监听该 IPv4；auto=自动探测内网 IP；all=不写（监听全部，不推荐）
  [string]$AllowFrom,          # 防火墙仅放行该来源 IP（逗号分隔）；空=不限来源
  [switch]$SkipInstall,
  [switch]$DryRun,
  [ValidateSet('Auto','Msi','Zip','Dism','Winget','Capability')][string]$InstallMethod = 'Auto',
  [string]$MsiPath,
  [string]$OpenSSHZipPath,
  [string]$DownloadUrl,        # 自定义源：直接给 msi/zip 的完整 URL，优先于内置镜像
  [string]$ProxyUrl,           # 自定义代理：如 http://127.0.0.1:2080
  [int]   $DownloadTimeoutSec = 180,
  [string]$PublicKeyFile,               # 公钥文件路径（-PublicKey 未给/为占位符时读这里）
  [string]$InstallDir = (Join-Path $env:ProgramData 'WinVMDeploy'),  # 本脚本自留目录（卸载时 -Rollback 的固定路径）
  [switch]$NoSelfStage,                 # 跳过"把自己复制到 InstallDir"（自检/测试用）
  [string[]]$SelfUrl = @(),             # irm|iex 模式的自落盘源（可多个，按序回退）；缺省用技能仓 raw@main
  [switch]$NoSelfFetch                  # irm|iex 模式下禁止联网自下载（离线/纯演练用）
)

$SCRIPT_VERSION = '2.4.0'
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # 下载不写进度条（PS5.1 进度条会拖慢 3-5 倍）
if ($env:SSH_CONNECTION) { try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {} }

# =====================================================================
#  自留存量（v2.4.0）
#  本脚本由部署流程从远端下载后直接执行；执行时把自身复制到固定目录，
#  这样卸载阶段有一条确定路径可用：
#     powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1 -Rollback
#  journal 在 C:\ProgramData\ssh\wb-tunnel-state.json，与本脚本位置无关，故复制不影响可逆性。
# =====================================================================
$script:SelfStaged    = $false
$script:SelfStageMode = 'none'          # copy / existing / fetch / none
$script:SelfUrlUsed   = ''
$script:SelfPathFinal = Join-Path $InstallDir 'winvm-sshd-oneclick.ps1'
# 缺省自落盘源：技能源仓已 public，raw@main 匿名可下，且永远是最新版（不带 tag 是为了
# 兼容 irm|iex——这种执行方式拿不到任何版本上下文）。
$script:SelfUrlDefault = 'https://raw.githubusercontent.com/athronix/winvm-plugin-deploy/main/scripts/winvm-sshd-oneclick.ps1'

if (-not $NoSelfStage) {
  try {
    $src = ''
    try { $src = [string]$PSCommandPath } catch { $src = '' }
    if (-not $src) { try { $src = [string]$MyInvocation.MyCommand.Path } catch { $src = '' } }
    $finalFull = [IO.Path]::GetFullPath($script:SelfPathFinal)
    $srcFull = ''
    if ($src) { try { $srcFull = [IO.Path]::GetFullPath($src) } catch { $srcFull = '' } }

    if ($srcFull -and (Test-Path -LiteralPath $srcFull) -and ($srcFull -ne $finalFull)) {
      # 1) 常规 -File 执行：复制自身
      New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
      Copy-Item -LiteralPath $srcFull -Destination $script:SelfPathFinal -Force
      $script:SelfStaged = $true; $script:SelfStageMode = 'copy'
    } elseif (Test-Path -LiteralPath $script:SelfPathFinal) {
      # 2) 已落盘（重复执行）
      $script:SelfStaged = $true; $script:SelfStageMode = 'existing'
    } elseif (-not $NoSelfFetch) {
      # 3) irm <url> | iex —— $PSCommandPath 为空，内存里只有脚本文本。
      #    必须先把自身下载落盘，否则将来没有 -Rollback 可执行文件（通道拆不掉）。
      $srcList = @()
      foreach ($u in @($SelfUrl)) { if (-not [string]::IsNullOrWhiteSpace($u)) { $srcList += $u.Trim() } }
      if ($script:SelfUrlDefault) { $srcList += $script:SelfUrlDefault }
      New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
      $tmo = 45
      if ($DownloadTimeoutSec -gt $tmo) { $tmo = $DownloadTimeoutSec }
      foreach ($u in $srcList) {
        try {
          Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $script:SelfPathFinal -TimeoutSec $tmo -ErrorAction Stop
          if ((Test-Path -LiteralPath $script:SelfPathFinal) -and ((Get-Item -LiteralPath $script:SelfPathFinal).Length -gt 1024)) {
            $script:SelfStaged = $true; $script:SelfStageMode = 'fetch'; $script:SelfUrlUsed = $u
            break
          }
        } catch { }
      }
      if (-not $script:SelfStaged) {
        Remove-Item -LiteralPath $script:SelfPathFinal -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
}

# 公钥来源：-PublicKey 优先；为空或仍是模板占位符时从 -PublicKeyFile 读。
if (([string]::IsNullOrWhiteSpace($PublicKey) -or $PublicKey -eq '__PUBKEY__') -and $PublicKeyFile) {
  try { if (Test-Path -LiteralPath $PublicKeyFile) { $PublicKey = ([IO.File]::ReadAllText($PublicKeyFile)).Trim() } } catch { }
}

$SSHD_CFG  = 'C:\ProgramData\ssh\sshd_config'
$LogDir    = 'C:\ProgramData\ssh'
$StateFile = Join-Path $LogDir 'wb-tunnel-state.json'
$OrigBak   = $SSHD_CFG + '.wb-orig'
$dryRunMode   = [bool]$DryRun
$rollbackMode = [bool]$Rollback
$diagMode     = [bool]$ContinueMode
$doHarden     = [bool]$Harden     # 默认**不**收紧：保留密码登录等环境原状
$script:ProxyUrl = $ProxyUrl
# 在脚本作用域取一次"用户是否显式指定了 -InstallMethod"（函数内 $PSBoundParameters 看不到脚本参数）
$script:MethodExplicit = $PSBoundParameters.ContainsKey('InstallMethod')

$script:InstallUsed  = ''
$script:EmptyUsed      = ''      # 实际生效的空密码策略（auto 解析后的 yes/no）
$script:MsiUsed        = ''
$script:MsiSourceUrl   = ''
$script:MsiProductCode = ''
$script:MsiLogFile     = ''
$script:LogFile    = $null
$script:Mode       = 'build'
$script:StageIdx   = 0
$script:StageTotal = 9
$script:StageName  = '初始化'
$script:StageSw    = $null
$script:state      = $null
$script:LastOpRef  = $null
$script:ConfigChanged = $false
$script:Baseline   = $null
$script:IsAdmin    = $false
$script:SelfPath   = ''
$script:SelfSha    = ''

# =====================================================================
#  输出层：同一句话同时进控制台（带颜色）和日志文件（带时间戳）
# =====================================================================
function Write-Log {
  param([string]$Level = 'INFO', [string]$Message = '')
  if (-not $script:LogFile) { return }
  try {
    Add-Content -Path $script:LogFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Level, $Message) -Encoding UTF8
  } catch {}
}

function Say {
  param([string]$Message = '', [string]$Color = 'Gray')
  try { Write-Host $Message -ForegroundColor $Color } catch { Write-Host $Message }
  Write-Log 'INFO' $Message
}

function Info   { param([string]$m) Say ("[*] " + $m) 'Cyan' }
function Ok     { param([string]$m) Say ("[+] " + $m) 'Green' }
function Warn   { param([string]$m) Say ("[!] " + $m) 'Yellow' }
function Err    { param([string]$m) Say ("[x] " + $m) 'Red' }
function Step   { param([string]$m) Say ("  -> " + $m) 'Gray' }
function Detail { param([string]$m) Say ("     " + $m) 'DarkGray' }

function Initialize-Log {
  param([string]$Mode = 'build', [string]$Title = '')
  $script:Mode = $Mode
  # 落盘策略：
  #   DryRun        -> %TEMP%（预演必须零副作用，不碰 C:\ProgramData）
  #   diag/rollback -> C:\ProgramData\ssh 已存在才用它，否则 %TEMP%（不为写日志去创建系统目录）
  #   build         -> 固定 C:\ProgramData\ssh（journal 也在这里，必须建）
  $dir = $LogDir
  if ($dryRunMode) { $dir = $env:TEMP }
  elseif ($Mode -ne 'build' -and -not (Test-Path $LogDir)) { $dir = $env:TEMP }
  try {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $dir ("wb-tunnel-{0}-{1}.log" -f $Mode, $stamp)
    $bar = ('=' * 78)
    Add-Content -Path $script:LogFile -Value $bar -Encoding UTF8
    Add-Content -Path $script:LogFile -Value ("wb-tunnel v{0}  mode={1}  {2}" -f $SCRIPT_VERSION, $Mode, $Title) -Encoding UTF8
    Add-Content -Path $script:LogFile -Value ("time={0}" -f (Get-Date -Format 'o')) -Encoding UTF8
    Add-Content -Path $script:LogFile -Value ("host={0}  user={1}  ps={2}  admin={3}  script={4}" -f $env:COMPUTERNAME, $User, $PSVersionTable.PSVersion, $script:IsAdmin, $script:SelfPath) -Encoding UTF8
    Add-Content -Path $script:LogFile -Value $bar -Encoding UTF8
  } catch { $script:LogFile = $null }
}

function Enter-Stage {
  param([string]$Name)
  $script:StageIdx++
  $script:StageName = $Name
  $script:StageSw = [System.Diagnostics.Stopwatch]::StartNew()
  Say ''
  Say ("=== [{0}/{1}] {2}   开始 {3} ===" -f $script:StageIdx, $script:StageTotal, $Name, (Get-Date -Format 'HH:mm:ss')) 'White'
}

function Exit-Stage {
  param([string]$Note = '')
  $el = 0
  if ($script:StageSw) { $el = [int]$script:StageSw.Elapsed.TotalSeconds }
  $script:StageSw = $null
  Say ("    [阶段 {0} 完成] 用时 {1}s {2}" -f $script:StageIdx, $el, $Note) 'Green'
}

# =====================================================================
#  通用工具
# =====================================================================
function Get-Sha256Text {
  param([string]$Text)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
  } catch { return '' }
}

function Get-FileShaSafe {
  param([string]$Path)
  try { return (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return '' }
}

function Get-AclSddl {
  param([string]$Path)
  try { return (Get-Acl -Path $Path -ErrorAction Stop).Sddl } catch { return '' }
}

function Restore-AclSddl {
  param([string]$Path, [string]$Sddl)
  if (-not $Sddl) { return 'no-sddl' }
  if (-not (Test-Path $Path)) { return 'missing-path' }
  $a = Get-Acl -Path $Path -ErrorAction Stop
  $a.SetSecurityDescriptorSddlForm($Sddl)
  Set-Acl -Path $Path -AclObject $a -ErrorAction Stop
  return 'acl-restored'
}

function Test-Tcp {
  param([string]$Target, [int]$TcpPort, [int]$TimeoutMs = 2000)
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($Target, $TcpPort, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
    $c.EndConnect($ar)
    return $true
  } catch { return $false } finally { if ($c) { try { $c.Close() } catch {} } }
}

function Get-SshClientExe {
  foreach ($c in @(
      (Join-Path $env:ProgramFiles 'OpenSSH\ssh.exe'),
      (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'))) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return $null
}

# ---- none 认证探测：判定"是否退化成匿名登录"（本 skill 最关键的健康指标）----
# 返回 'rejected'/'rejected-config'（正确） / 'accepted'/'accepted-config'（危险） / 'nokey' / 'unknown'
#
# 重修原因（2026-11-10 实测）：
#   早先的实现无条件 `& ssh.exe ...` 从 build 进程里发起，而 build 本身常常是"用户在 ssh 里再跑 -> 又起一个 ssh"：
#     · 子 ssh 会去读控制台 stdin，在非交互会话里**直接挂住**（实测 >4 分钟不退）
#     · `-F NUL` 在 Win32-OpenSSH 上不可靠，会退化成 "Host key verification failed"，只落进 'unknown'
#   于是日志长期是"无法判定（连接异常）"—— 一个永远黄灯的探测等于没有探测。
#
# 新策略：**先看生效配置，再决定要不要联网**
#   PermitEmptyPasswords no  -> none 在 sshd 层就不可能通过（auth2-none.c 要求前者为 yes），直接 'rejected-config'，零网络、零挂起
#   否则（=yes 且账户空密码）  -> 'accepted-config'，与实测等价
#   只有配置既非 no 又算不清时才发一次**带超时的**子进程探测（-n 关掉 stdin，8s 强杀）
function Get-SshdEffectiveEmpty {
  $sshd = Get-SshdExe
  if (-not $sshd) { return '' }
  try {
    $t = & $sshd -T 2>&1
    foreach ($line in $t) {
      if ("$line" -match '^\s*permitemptypasswords\s+(\S+)') { return $matches[1].ToLower() }
    }
  } catch {}
  return ''
}

function Test-NoAuthAccepted {
  param([string]$Target = '127.0.0.1', [int]$TcpPort = 22, [string]$UserName)

  # (1) 配置层：确定性判定，不联网
  $effEmpty = Get-SshdEffectiveEmpty
  if ($effEmpty -eq 'no') { return 'rejected-config' }
  if ($effEmpty -eq 'yes') {
    $blank = $true
    try { $blank = Test-AccountHasBlankPassword $UserName } catch { $blank = $true }
    if ($blank) { return 'accepted-config' }   # 空密码账户 + 放行空密码 => none 直通
    return 'rejected-config'                   # 账户有密码 => none 仍会被拒
  }

  # (2) 配置读不出来时才联网探测；必须 -n（stdin=NUL）+ 硬超时，否则会挂
  $cli = Get-SshClientExe
  if (-not $cli) { return 'nokey' }
  $kh  = Join-Path $env:TEMP 'wb-none-probe.known_hosts'
  $cfg = Join-Path $env:TEMP 'wb-none-probe.cfg'
  foreach ($f in @($kh, $cfg)) { try { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } } catch {} }
  try { New-Item -ItemType File -Path $cfg -Force | Out-Null } catch { return 'nokey' }

  $out = ''
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cli
    $psi.Arguments = ('-n -F "{0}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="{1}" ' +
                      '-o PreferredAuthentications=none -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=0 ' +
                      '-o ConnectTimeout=5 -p {2} "{3}@{4}" "echo WB_NONE_AUTH_ACCEPTED"') -f `
                      $cfg, $kh, $TcpPort, $UserName, $Target
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.CreateNoWindow         = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    try { $p.StandardInput.Close() } catch {}
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(8000)) {
      try { $p.Kill() } catch {}
      return 'unknown'
    }
    $out = [string]$tOut.Result + [string]$tErr.Result
  } catch {
    $out = ''
  } finally {
    if ($p) { try { $p.Dispose() } catch {} }
    foreach ($f in @($kh, $cfg)) { try { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } } catch {} }
  }
  if ($out -match 'WB_NONE_AUTH_ACCEPTED') { return 'accepted' }
  if ($out -match 'Permission denied') { return 'rejected' }
  return 'unknown'
}

function Write-NoneAuthVerdict {
  param([string]$State)
  switch ($State) {
    'rejected' { Ok 'none 认证探测：已拒绝 —— 无凭据无法登录（正确，公钥才是唯一入口）' }
    'rejected-config' { Ok 'none 认证判定：不可能是匿名登录（PermitEmptyPasswords=no，或账户本身有密码）' }
    'accepted-config' {
      Warn '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
      Warn ' none 认证判定：**空密码账户 + PermitEmptyPasswords=yes => 无凭据可直接登录！**'
      Warn ' 此时公钥认证根本用不到，"免密通道"等于"匿名通道"。'
      Warn ' 处置：改成 PermitEmptyPasswords no 后重启 sshd（本脚本默认就是这个值）。'
      Warn '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    }
    'accepted' {
      Warn '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
      Warn ' none 认证探测：**被接受** —— 任何人无需凭据即可登录！'
      Warn ' 说明 sshd_config 里 PermitEmptyPasswords=yes（空密码账户会触发 none 直通）。'
      Warn ' 此时公钥认证根本用不到，"免密通道"等于"匿名通道"。'
      Warn ' 处置：改成 PermitEmptyPasswords no 后重启 sshd（本脚本默认就是这个值）。'
      Warn '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    }
    'nokey' { Warn 'none 认证探测：跳过（未找到 ssh.exe 客户端；请回宿主机用 verify-tunnel.sh 验证）' }
    default { Warn 'none 认证探测：无法判定（sshd -T 与联网探测都没结论）；请回宿主机用 verify-tunnel.sh 验证' }
  }
}

function Get-UserProfileDir {
  param([string]$Name)
  $guess = Join-Path 'C:\Users' $Name
  if (Test-Path $guess) { return $guess }
  try {
    $p = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
         Where-Object { $_.LocalPath -and ($_.LocalPath -match ('\\' + [regex]::Escape($Name) + '$')) } |
         Select-Object -First 1
    if ($p) { return $p.LocalPath }
  } catch {}
  return $guess
}

function Get-SshdExe {
  $svc = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
  if ($svc -and $svc.PathName) {
    if ($svc.PathName -match '^\s*"([^"]+)"') { return $matches[1] }
    return ($svc.PathName -split '\s+')[0]
  }
  foreach ($c in @('C:\Windows\System32\OpenSSH\sshd.exe', 'C:\Program Files\OpenSSH\sshd.exe')) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

# ---- 账户密码状态 / 空密码网络登录策略（只读探测 + 可逆修改）---------------
function Get-AccountFlagPasswdNotReqd {
  # UF_PASSWD_NOTREQD(0x0020)：账户"不要求密码"。空密码账户一般都会带这个位。
  # 先读标志位、再决定要不要真的试登录 —— 避免对"有密码"的账户做无谓的失败登录
  # （会累计 bad-password 计数，极端策略下可能触发锁定）。
  param([string]$Name)
  try {
    $u = [ADSI]("WinNT://{0}/{1},user" -f $env:COMPUTERNAME, $Name)
    return (([int]$u.UserFlags.Value -band 0x0020) -ne 0)
  } catch { return $null }
}

function Test-AccountHasBlankPassword {
  # 返回 $true=确认没密码 / $false=确认有密码 / $null=判不出来
  param([string]$Name)
  $notReqd = Get-AccountFlagPasswdNotReqd $Name
  if ($notReqd -eq $false) { return $false }   # 明确"要求密码"-> 不必试登录
  try {
    if (-not ('WbBlankPwdProbe' -as [type])) {
      $def = @'
public class WbBlankPwdProbe {
  [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
  public static extern bool LogonUser(string u, string d, string p, int t, int pr, out System.IntPtr ph);
  [System.Runtime.InteropServices.DllImport("kernel32.dll")]
  public static extern bool CloseHandle(System.IntPtr h);
}
'@
      Add-Type -TypeDefinition $def -ErrorAction Stop
    }
    $h = [System.IntPtr]::Zero
    # 3 = LOGON32_LOGON_NETWORK：ssh 密码认证走的就是网络登录，最能代表真实可用性
    $ok = [WbBlankPwdProbe]::LogonUser($Name, '.', '', 3, 0, [ref]$h)
    if ($h -ne [System.IntPtr]::Zero) { try { [void][WbBlankPwdProbe]::CloseHandle($h) } catch {} }
    if ($ok) { return $true }
    $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    # 1327=账户限制：空密码 + LimitBlankPasswordUse=1 时就是它 -> 空密码确实存在，只是被策略拦住
    if ($code -eq 1327) { return $true }
    # 1326=用户名或密码错 -> 该账户是有密码的
    if ($code -eq 1326) { return $false }
    if ($notReqd -eq $true) { return $true }
    return $null
  } catch {
    if ($notReqd -eq $true) { return $true }
    try {
      $out = (& net.exe user $Name 2>&1 | Out-String)
      if ($out -match '(?im)^\s*(Password required|需要密码|密碼)\s*[:：]?\s*(\S+)') {
        $v = [string]$Matches[2]
        if ($v -match '^(No|NO|no|否)$')  { return $true }
        if ($v -match '^(Yes|YES|yes|是)$') { return $false }
      }
    } catch {}
    return $null
  }
}

function Get-LsaBlankPasswordPolicy {
  $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  try {
    $v = Get-ItemProperty -Path $p -Name 'LimitBlankPasswordUse' -ErrorAction Stop
    return [int]$v.LimitBlankPasswordUse
  } catch { return $null }   # 值不存在 = 系统用默认（1）
}

# =====================================================================
#  journal 层
# =====================================================================
function Ensure-Prop {
  # 老版本账本（v1）没有 undoState/status/buildCount 等字段；直接赋值会报"对象没有此属性"。
  # 统一在这里补齐（用 PSNoteProperty，可安全承载 $null）。
  param($Obj, [string]$Name, $Default = $null)
  if ($null -eq $Obj) { return }
  $has = $false
  try { $has = ($Obj.PSObject.Properties.Name -contains $Name) } catch { $has = $false }
  if ($has) { return }
  try {
    $np = [System.Management.Automation.PSNoteProperty]::new($Name, $Default)
    $Obj.PSObject.Properties.Add($np)
  } catch {}
}

function Upgrade-WbState {
  param($st)
  if (-not $st) { return $st }
  Ensure-Prop $st 'schema' 1
  Ensure-Prop $st 'status' 'active'
  Ensure-Prop $st 'createdAt' (Get-Date).ToString('o')
  Ensure-Prop $st 'updatedAt' (Get-Date).ToString('o')
  Ensure-Prop $st 'buildCount' 1
  if ($null -eq $st.params) { Ensure-Prop $st 'params' ([pscustomobject]@{}) }
  if ($null -eq $st.env) { Ensure-Prop $st 'env' ([pscustomobject]@{}) }
  Ensure-Prop $st 'baseline' $null
  if ($null -eq $st.rollbacks) { Ensure-Prop $st 'rollbacks' @() }
  if ($st.params) {
    foreach ($n in @('user', 'port', 'harden', 'publicKeyBlob', 'publicKeySha256', 'publicKeyComment')) {
      Ensure-Prop $st.params $n $null
    }
  }
  if ($st.ops) {
    foreach ($o in @($st.ops)) {
      Ensure-Prop $o 'stage' 0
      Ensure-Prop $o 'stageName' 'legacy'
      Ensure-Prop $o 'result' 'ok'
      Ensure-Prop $o 'after' $null
      Ensure-Prop $o 'undoState' $(if ($o.undo) { 'pending' } else { 'none' })
      Ensure-Prop $o 'undoTs' $null
      Ensure-Prop $o 'undoResult' $null
    }
  }
  return $st
}

function Read-WbState {
  if (-not (Test-Path $StateFile)) { return $null }
  try {
    $st = Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st.ops -and -not ($st.ops -is [System.Array])) { $st.ops = @($st.ops) }
    if ($st.rollbacks -and -not ($st.rollbacks -is [System.Array])) { $st.rollbacks = @($st.rollbacks) }
    return (Upgrade-WbState $st)
  } catch { return $null }
}

function Set-LastOpAfter {
  # 给"刚记录的那条 op"补充 after 字段（兼容 dic / pscustomobject 两种形态）
  param([string]$Key, $Value)
  if ($dryRunMode) { return }   # 预演不写任何 op（包括不改旧条目）
  $op = $null
  if ($script:LastOpRef) { $op = $script:LastOpRef }
  else {
    $arr = @($script:state.ops)
    if ($arr.Count -eq 0) { return }
    $op = $arr[$arr.Count - 1]
  }
  if (-not $op) { return }
  if ($op.after -is [System.Collections.IDictionary]) { $op.after[$Key] = $Value; return }
  if ($op.after) {
    try { $op.after | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force } catch {}
  }
}

function Set-LastOpUndo {
  # 给"刚记录的那条 op"补充 undo 参数（典型：.ssh 目录的原始 ACL）
  param([string]$Key, $Value)
  if ($dryRunMode) { return }   # 预演不写任何 op（包括不改旧条目）
  $op = $null
  if ($script:LastOpRef) { $op = $script:LastOpRef }
  else {
    $arr = @($script:state.ops)
    if ($arr.Count -eq 0) { return }
    $op = $arr[$arr.Count - 1]
  }
  if (-not $op) { return }
  if ($op.undo -is [System.Collections.IDictionary]) { $op.undo[$Key] = $Value; return }
  if ($op.undo) {
    try { $op.undo | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force } catch {}
  }
}

function Save-WbState {
  param($st)
  $d = Split-Path -Parent $StateFile
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  ($st | ConvertTo-Json -Depth 12) | Set-Content -Path $StateFile -Encoding UTF8
}

function Add-Op {
  param(
    [string]$Action,
    $Before,
    $Undo,
    $After,
    [string]$Result = 'ok',
    [string]$Key = ''
  )
  if (-not $script:state) { return }

  # DryRun 绝不能"伪造"一条 journal —— 那会让人误以为账本已写入。
  # 只打印"将记录什么"，然后直接返回（不追加、不落盘、不动 LastOpRef）。
  if ($dryRunMode) {
    $k = ''
    if ($Key) { $k = " key=$Key" }
    Detail ("[journal 预演] 将记录：{0}{1}{2}" -f $Action, $k, $(if ($Undo) { ' / undo=' + [string]$Undo.type } else { ' / 无 undo' }))
    return
  }

  # ---- 幂等 upsert：同一 (action,key) 且尚未撤销 -> 不追加新条目，只刷新 after/result，before 永远保留首次 ----
  if ($Key) {
    $prev = @($script:state.ops) |
      Where-Object { $_.action -eq $Action -and [string]$_.key -eq $Key -and [string]$_.undoState -ne 'done' } |
      Select-Object -Last 1
    if ($prev) {
      # 老账本可能缺字段：先补齐再赋值（PSCustomObject 直接赋值不存在的属性会抛错）
      foreach ($f in @('times', 'tsLast', 'after', 'result', 'stage', 'stageName', 'undo', 'key')) {
        Ensure-Prop $prev $f $null
      }
      if ($null -eq $prev.times) { $prev.times = 1 }
      $prev.times     = [int]$prev.times + 1
      $prev.after     = $After
      $prev.result    = $Result
      $prev.tsLast    = (Get-Date).ToString('o')
      $prev.stage     = $script:StageIdx
      $prev.stageName = $script:StageName
      # undo 绝不能被后续重跑覆盖：
      # 首次 before.existed=false -> undo=remove_firewall_rule（该删）
      # 重跑时规则已存在        -> undo=restore_firewall_rule（该还原）
      # 若让后者覆盖前者，destroy 就会"还原成存在"，留下本该不存在的残留。
      # 只在首次 undo 为空（无改动）时才补写。
      if ($Undo -and -not $prev.undo) { $prev.undo = $Undo }
      $script:LastOpRef = $prev
      $script:state.updatedAt = (Get-Date).ToString('o')
      if (-not $dryRunMode) { Save-WbState $script:state }
      Detail ("[journal #{0}] {1}（幂等更新：before 保留首次，after 刷新，累计 {2} 次）" -f $prev.id, $Action, $prev.times)
      return
    }
  }

  $op = [ordered]@{
    id         = (@($script:state.ops).Count + 1)
    ts         = (Get-Date).ToString('o')
    tsLast     = (Get-Date).ToString('o')
    times      = 1
    stage      = $script:StageIdx
    stageName  = $script:StageName
    action     = $Action
    key        = $Key
    before     = $Before
    after      = $After
    result     = $Result
    undo       = $Undo
    undoState  = $(if ($Undo) { 'pending' } else { 'none' })
    undoTs     = $null
    undoResult = $null
  }
  $script:state.ops = @($script:state.ops) + @($op)
  $script:LastOpRef = $op
  $script:state.updatedAt = (Get-Date).ToString('o')
  if (-not $dryRunMode) { Save-WbState $script:state }
  $tag = '无改动'
  if ($Undo) { $tag = '可撤销:' + [string]$Undo.type }
  Detail ("[journal #{0}] {1}（{2}）" -f $op.id, $Action, $tag)
  return
}

function Get-BaselineSnapshot {
  $b = [ordered]@{ ts = (Get-Date).ToString('o') }

  # sshd 服务
  $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
  $b.sshdServiceExisted   = [bool]$svc
  $b.sshdServiceStatus    = $(if ($svc) { [string]$svc.Status } else { 'absent' })
  $b.sshdServiceStartType = $(if ($svc) { [string]$svc.StartType } else { 'absent' })
  $b.sshdExe              = [string](Get-SshdExe)

  # 可选功能
  if ($dryRunMode) {
    $b.capability = 'dryrun-skipped'
  } else {
    $b.capability = 'unknown'
    try {
      $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop | Select-Object -First 1
      if ($cap) { $b.capability = [string]$cap.State }
    } catch { $b.capability = 'query-failed' }
  }

  # 配置
  $b.configExisted = Test-Path $SSHD_CFG
  $b.configSha256  = $(if (Test-Path $SSHD_CFG) { Get-FileShaSafe $SSHD_CFG } else { '' })
  $b.origStashExisted = Test-Path $OrigBak
  $b.sshDirExisted = Test-Path $LogDir

  # 网络配置档
  $profs = @()
  try {
    foreach ($p in @(Get-NetConnectionProfile -ErrorAction Stop)) {
      $profs += [ordered]@{ alias = [string]$p.InterfaceAlias; name = [string]$p.Name; category = [string]$p.NetworkCategory }
    }
  } catch {}
  $b.netProfiles = @($profs)

  # 防火墙规则
  $fwList = @()
  foreach ($n in @('OpenSSH-Server-In-TCP', 'OpenSSH-Server-In-TCP-WB')) {
    $fw = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
    if (-not $fw) {
      $fwList += [ordered]@{ name = $n; existed = $false }
    } else {
      $portVal = ''
      try { $portVal = [string]($fw | Get-NetFirewallPortFilter -ErrorAction Stop).LocalPort } catch {}
      $fwList += [ordered]@{
        name = $n; existed = $true; enabled = [bool]$fw.Enabled;
        profile = [string]$fw.Profile; action = [string]$fw.Action; localPort = $portVal
      }
    }
  }
  $b.firewall = @($fwList)

  # 授权文件（含 ACL SDDL）
  $akList = @()
  $adminAk = 'C:\ProgramData\ssh\administrators_authorized_keys'
  foreach ($p in @($adminAk, (Join-Path (Join-Path (Get-UserProfileDir $User) '.ssh') 'authorized_keys'))) {
    if (Test-Path $p) {
      $lines = @(Get-Content -Path $p -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
      $hasOurs = (@($lines | Where-Object { $_ -match 'workbuddy-hos-winvm-tunnel|wb-tunnel' }).Count -gt 0)
      $akList += [ordered]@{ path = $p; existed = $true; lines = $lines.Count; acl = (Get-AclSddl $p); hasTunnelKey = $hasOurs }
    } else {
      $akList += [ordered]@{ path = $p; existed = $false; lines = 0; acl = ''; hasTunnelKey = $false }
    }
  }
  $b.authFiles = @($akList)

  # 账户策略（只读策略位，绝不读/写密码）
  $acct = [ordered]@{ name = $User; exists = $false }
  try {
    $lu = Get-LocalUser -Name $User -ErrorAction Stop
    $acct.exists           = $true
    $acct.enabled          = [bool]$lu.Enabled
    $acct.passwordRequired = [bool]$lu.PasswordRequired
    $acct.passwordLastSet  = $(if ($lu.PasswordLastSet) { ([datetime]$lu.PasswordLastSet).ToString('o') } else { 'never' })
    $acct.lastLogon        = $(if ($lu.LastLogon) { ([datetime]$lu.LastLogon).ToString('o') } else { 'never' })
  } catch { $acct.error = 'query-failed' }
  $b.account = $acct

  return $b
}

function New-Journal {
  $prev = Read-WbState

  # 未回滚的账本：一律沿用（保留首次 baseline，后续操作叠加）。
  # 只有 status=rolledback 才是"上一轮已清算"，才归档重开。
  if ($prev -and [string]$prev.status -ne 'rolledback') {
    $oc = @($prev.ops).Count
    Ok ("沿用已有 journal：{0} 条 ops（建于 {1}，status={2}）" -f $oc, $prev.createdAt, $prev.status)
    Detail '本次构建在其后叠加记录；同目标的写操作按 (action,key) 幂等更新，不产生重复条目；baseline 保留首次的'
    $prev.buildCount = [int]$prev.buildCount + 1
    $prev.updatedAt  = (Get-Date).ToString('o')
    $prev.status     = 'active'
    if (-not $dryRunMode) { Save-WbState $prev }
    return $prev
  }
  if ($prev) {
    if ($dryRunMode) {
      Detail 'DryRun：存在旧账本（status=rolledback），正式执行时会归档后重开'
    } else {
      $hist = Join-Path $LogDir ("wb-tunnel-state.history-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
      try {
        Copy-Item -Path $StateFile -Destination $hist -Force -ErrorAction Stop
        Ok ("上一份账本（已回滚）已归档 -> {0}" -f $hist)
      } catch { Warn ("旧账本归档失败（继续）：{0}" -f $_.Exception.Message) }
    }
  }

  $st = [ordered]@{
    schema     = 2
    version    = $SCRIPT_VERSION
    status     = 'active'
    createdAt  = (Get-Date).ToString('o')
    updatedAt  = (Get-Date).ToString('o')
    buildCount = 1
    host       = $env:COMPUTERNAME
    params     = [ordered]@{
      user             = $User
      port             = $Port
      harden           = $doHarden
      emptyPassword    = [string]$EmptyPasswordMode
      skipInstall      = [bool]$SkipInstall
      keepService      = [bool]$KeepService
      dryRun           = $dryRunMode
      installMethod    = [string]$InstallMethod
      msiPath          = [string]$MsiPath
      openSshZipPath   = [string]$OpenSSHZipPath
      downloadTimeout  = $DownloadTimeoutSec
      publicKey        = [string]$PublicKey
      publicKeyBlob    = ''
      publicKeySha256  = ''
      publicKeyComment = ''
    }
    env        = [ordered]@{
      computerName = $env:COMPUTERNAME
      os           = ''
      psVersion    = [string]$PSVersionTable.PSVersion
      isAdmin      = $script:IsAdmin
      userContext  = [string]$env:USERNAME
      scriptPath   = $script:SelfPath
      scriptSha256 = $script:SelfSha
      scriptVer    = $SCRIPT_VERSION
    }
    baseline   = $script:Baseline
    ops        = @()
    rollbacks  = @()
  }

  $osName = ''
  try { $osName = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $osName = [string]$PSVersionTable.OS }
  $st.env.os = $osName

  if ($script:Baseline) { $st.baseline = $script:Baseline }

  if (-not $dryRunMode) {
    Save-WbState $st
    Ok ("journal 已建立 -> {0}" -f $StateFile)
  } else {
    Detail 'DryRun：journal 只打印不落盘'
  }
  return $st
}

# =====================================================================
#  回滚层
# =====================================================================
function Remove-KeyFromFile {
  param([string]$Path, [string]$KeyBlob, [bool]$FileExisted = $false)
  if (-not (Test-Path $Path)) { return 'absent' }
  $all  = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
  $keep = @($all | Where-Object { $_ -and (-not $_.Contains($KeyBlob)) })
  $before = @($all  | Where-Object { $_ -and $_.Trim() }).Count
  $after  = @($keep | Where-Object { $_ -and $_.Trim() }).Count
  if ($before -eq $after) { return 'unchanged' }
  if ($after -eq 0 -and -not $FileExisted) {
    Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    return 'removed-file'
  }
  Set-Content -Path $Path -Value $keep -Encoding Ascii
  return 'removed-line'
}

function Invoke-Undo {
  param($Op)
  $u = $Op.undo
  $t = [string]$u.type
  switch ($t) {
    'restore_file' {
      $from = [string]$u.from; $to = [string]$u.path
      if (-not $from -or -not (Test-Path $from)) { throw "留档已不存在：$from" }
      Copy-Item -Path $from -Destination $to -Force -ErrorAction Stop
      return ("restore_file -> {0}（来自 {1}）" -f $to, (Split-Path -Leaf $from))
    }
    'delete_file' {
      $p = [string]$u.path
      if (Test-Path $p) { Remove-Item -Path $p -Force -ErrorAction Stop; return ("deleted {0}" -f $p) }
      return ("already-absent {0}" -f $p)
    }
    'remove_key_line' {
      $p = [string]$u.path; $b = [string]$u.blob
      $fileExisted = [bool]$u.fileExisted
      $r = Remove-KeyFromFile -Path $p -KeyBlob $b -FileExisted $fileExisted
      $extra = @()
      if ((Test-Path $p) -and $u.acl) {
        try { Restore-AclSddl -Path $p -Sddl ([string]$u.acl) | Out-Null; $extra += 'acl-restored' }
        catch { $extra += ('acl-failed:' + (($_.Exception.Message -split "`n")[0])) }
      }
      $d = Split-Path -Parent $p
      if ($u.dirExisted -eq $false) {
        if ((Test-Path $d) -and -not (Get-ChildItem -Path $d -Force -ErrorAction SilentlyContinue)) {
          Remove-Item -Path $d -Force -ErrorAction SilentlyContinue
          $extra += 'dir-removed'
        }
      } elseif ((Test-Path $d) -and $u.dirAcl) {
        # .ssh 目录原本存在、且我们改过它的 ACL -> 一并还原
        try { Restore-AclSddl -Path $d -Sddl ([string]$u.dirAcl) | Out-Null; $extra += 'dirAcl-restored' }
        catch { $extra += 'dirAcl-failed' }
      }
      if ($extra.Count -gt 0) { return ('remove_key_line:{0} +{1}' -f $r, ($extra -join ',')) }
      return ('remove_key_line:{0}' -f $r)
    }
    'restore_acl' {
      return (Restore-AclSddl -Path ([string]$u.path) -Sddl ([string]$u.sddl))
    }
    'remove_firewall_rule' {
      $n = [string]$u.name
      $fw = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
      if (-not $fw) { return ("already-absent rule {0}" -f $n) }
      Remove-NetFirewallRule -Name $n -ErrorAction Stop
      return ("removed rule {0}" -f $n)
    }
    'restore_firewall_rule' {
      $n = [string]$u.name
      $fw = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
      if (-not $fw) {
        # 规则已不存在 = 没有来源限制需要还，也没有残留 —— 对"只记了来源收窄"的场景这是**已完成**，
        # 不是失败。以前这里 throw，导致 destroy 汇总里出现假失败（#15/#16/#17 就是这个）。
        return ("already-absent rule {0}（无残留，无需还原来源）" -f $n)
      }
      $notes = @()
      # 逐字段"有记录才改"：
      #   · 缺失 enabled 时不能当成 False —— 那会把规则禁用，属于**过度还原**
      #     （firewall-narrow-existing 只记录了 remoteAddress，没有 enabled）
      #   · Enabled 必须传字符串 'True'/'False'：splatting/参数传 [bool] 会被
      #     NetSecurity.Enabled 枚举拒绝（Invalid cast from 'System.Boolean'）
      if ($null -ne $u.enabled -and [string]$u.enabled -ne '') {
        $enStr = 'False'
        if ([bool]$u.enabled) { $enStr = 'True' }
        Set-NetFirewallRule -Name $n -Enabled $enStr -ErrorAction Stop | Out-Null
        $notes += ('Enabled=' + $enStr)
      }
      $pf = [string]$u.profile
      if ($pf) {
        Set-NetFirewallRule -Name $n -Profile $pf -ErrorAction Stop | Out-Null
        $notes += ('Profile=' + $pf)
      }
      $portNote = ''
      if ($u.localPort) {
        try {
          $fw | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -LocalPort ([string]$u.localPort) -ErrorAction Stop | Out-Null
          $portNote = (' port->' + [string]$u.localPort)
        } catch { $portNote = ' port-unchanged' }
      }
      $remNote = ''
      if ($null -ne $u.remoteAddress -and [string]$u.remoteAddress -ne '') {
        try {
          $ra = @(([string]$u.remoteAddress) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
          $fw | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $ra -ErrorAction Stop | Out-Null
          $remNote = (' remote->' + ($ra -join '|'))
        } catch { $remNote = ' remote-unchanged' }
      }
      $summary = 'rule {0} -> ' + $(if ($notes.Count) { $notes -join ' ' } else { 'unchanged' })
      return ($summary + $portNote + $remNote)
    }
    'restore_registry_value' {
      $p = [string]$u.path; $nm = [string]$u.name
      if (-not (Test-Path $p)) { return ("registry-path-absent {0}" -f $p) }
      if ($null -eq $u.value -or [string]$u.value -eq '') {
        # 原本没有这个值 -> 删掉我们建的那个，恢复"不存在"
        if (Get-ItemProperty -Path $p -Name $nm -ErrorAction SilentlyContinue) {
          Remove-ItemProperty -Path $p -Name $nm -ErrorAction Stop
          return ("removed reg-value {0}\{1}" -f $p, $nm)
        }
        return ("reg-value-already-absent {0}\{1}" -f $p, $nm)
      }
      $kind = [string]$u.kind
      if (-not $kind) { $kind = 'DWord' }
      $v = $u.value
      if ($kind -in @('DWord', 'QWord')) { $v = [int64]$u.value }
      New-ItemProperty -Path $p -Name $nm -Value $v -PropertyType $kind -Force -ErrorAction Stop | Out-Null
      return ("reg {0}\{1} -> {2}" -f $p, $nm, $v)
    }
    'restore_net_profile' {
      $al = [string]$u.alias; $cat = [string]$u.category
      Set-NetConnectionProfile -InterfaceAlias $al -NetworkCategory $cat -ErrorAction Stop
      return ("{0} -> {1}" -f $al, $cat)
    }
    'restore_service_starttype' {
      $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
      if (-not $svc) { return 'service-absent（服务已不在，跳过）' }
      Set-Service -Name sshd -StartupType ([string]$u.value) -ErrorAction Stop
      return ("sshd StartType -> {0}" -f $u.value)
    }
    'remove_capability' {
      $n = [string]$u.name
      $c = $null
      try { $c = Get-WindowsCapability -Online -Name $n -ErrorAction Stop } catch {}
      if (-not $c -or [string]$c.State -ne 'Installed') { return ("capability 已不在：{0}" -f $n) }
      Remove-WindowsCapability -Online -Name $n -ErrorAction Stop | Out-Null
      return ("removed capability {0}" -f $n)
    }
    'uninstall_openssh' {
      $scr = [string]$u.script; $dir = [string]$u.dir; $wg = [string]$u.winget; $msi = [string]$u.msi
      $did = @()
      $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
      if ($svc) { try { Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue } catch {} }

      if ($msi) {
        # MSI 装的：优先走 msiexec /x（会连服务、程序目录、ProgramData 默认配置一起清干净）
        Detail ("msiexec /x {0} /qn ..." -f $msi)
        $p = Start-Process -FilePath 'msiexec.exe' `
          -ArgumentList @('/x', $msi, '/qn', '/norestart') -Wait -PassThru -NoNewWindow
        $did += ('msi-uninstall:' + [int]$p.ExitCode)
        if ([int]$p.ExitCode -notin @(0, 1605, 3010, 1641)) {
          Warn ("msiexec /x 返回 {0}，继续用脚本/删目录兜底" -f $p.ExitCode)
          if ($scr -and (Test-Path $scr)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scr *>&1 | Out-Null
            $did += 'uninstall-script'
          }
        }
      } elseif ($scr -and (Test-Path $scr)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scr *>&1 | Out-Null
        $did += 'uninstall-script'
      } elseif ($svc) {
        & sc.exe delete sshd *>&1 | Out-Null
        $did += 'sc-delete'
      } else {
        $did += 'no-service'
      }
      Start-Sleep -Seconds 1
      if ($dir -and (Test-Path $dir)) { Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue; $did += 'dir-removed' }
      if ($wg) { & winget uninstall --id $wg --exact --silent --disable-interactivity *>&1 | Out-Null; $did += 'winget-uninstall' }
      if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { $did += 'verified-absent' }
      else { $did += 'STILL-PRESENT' }
      return ('uninstall_openssh: ' + ($did -join ','))
    }
    'restart_service' {
      $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
      if (-not $svc) { return 'service-absent' }
      Restart-Service -Name sshd -Force -ErrorAction SilentlyContinue
      return 'sshd 已重启以生效'
    }
    'delete_task' {
      $tn = [string]$u.name
      & schtasks.exe /Delete /TN $tn /F *>&1 | Out-Null
      return ("deleted task {0}" -f $tn)
    }
    default {
      throw ("未知 undo 类型 '{0}'（#{1} {2}）" -f $t, $Op.id, $Op.action)
    }
  }
}

function Clear-TempLeftovers {
  # 构建/预演过程落在 %TEMP% 的东西，回滚时一并清掉（不留垃圾）
  $n = 0
  foreach ($p in @(
      (Join-Path $env:TEMP 'sshd_config.preview'),
      (Join-Path $env:TEMP 'wb-dryrun-base.conf'),
      (Join-Path $env:TEMP 'wb-base-min.conf'),
      (Join-Path $env:TEMP 'OpenSSH-Win64.zip'),
      (Join-Path $env:TEMP 'OpenSSH-Win64.msi')
    )) {
    if (Test-Path $p) { try { Remove-Item -Path $p -Force -ErrorAction Stop; $n++ } catch {} }
  }
  try {
    foreach ($d in @(Get-ChildItem -Path $env:TEMP -Directory -Filter 'openssh-extract-*' -ErrorAction SilentlyContinue)) {
      Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
      $n++
    }
  } catch {}
  # destroy-tunnel.sh 用 scp 上传的回滚副本（落在用户目录，不用 ProgramData\ssh）
  foreach ($rb in @(
      (Join-Path $LogDir 'wb-rollback.ps1'),
      (Join-Path $env:USERPROFILE 'wb-rollback.ps1'),
      (Join-Path $env:USERPROFILE 'Downloads\wb-rollback.ps1')
    )) {
    if ($rb -and (Test-Path $rb)) { try { Remove-Item -Path $rb -Force -ErrorAction Stop; $n++ } catch {} }
  }
  return $n
}

function Show-RollbackResiduals {
  # 回滚后的"残留自检"：只读，逐项回答"到底干净了没有"。
  # 目的：destroy 不能只报 done=NN，得让人一眼看出有没有留尾巴。
  param([bool]$KeptService = $false)
  Say ''
  Say '---------------- 残留自检（只读） ----------------' 'White'

  # 1) 服务
  $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if (-not $svc) {
    Ok 'sshd 服务     ：不存在（已卸载）'
  } elseif ($KeptService) {
    Detail ("sshd 服务     ：仍存在（{0}/{1}）—— -KeepService 保留，属预期" -f $svc.Status, $svc.StartType)
  } else {
    Warn ("sshd 服务     ：仍存在（{0}/{1}）—— 与构建前基线不符，请复查 journal 的 uninstall_openssh 项" -f $svc.Status, $svc.StartType)
  }

  # 2) 监听
  $lis = @()
  try { $lis = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) } catch {}
  if ($lis.Count -eq 0) { Ok ("监听 TCP {0}   ：无（端口已释放）" -f $Port) }
  else { Warn ("监听 TCP {0}   ：仍在监听 {1} 个地址（{2}）" -f $Port, $lis.Count, (($lis | ForEach-Object { $_.LocalAddress }) -join ',')) }

  # 3) 防火墙：覆盖该端口的规则
  $fwNames = @()
  try {
    foreach ($f in @(Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
      $lp = [string]$f.LocalPort
      if (-not $lp) { continue }
      foreach ($one in ($lp -split ',')) { if ($one.Trim() -eq [string]$Port) { $fwNames += [string]$f.InstanceID; break } }
    }
  } catch {}
  $fwNames = @($fwNames | Sort-Object -Unique)
  $our = @($fwNames | Where-Object { $_ -match '^(OpenSSH|WinVM-SSH)' })
  if ($our.Count -eq 0) { Ok ("防火墙规则    ：没有本通道相关规则（残 0 条）") }
  else { Warn ("防火墙规则    ：仍有 {0} 条与本通道相关：{1}" -f $our.Count, ($our -join ', ')) }

  # 4) 授权文件里还有没有我们的公钥（按写入时的注释标签识别；并区分"本次写入"vs"构建前遗留"）
  $found = @()
  foreach ($f in @('C:\ProgramData\ssh\administrators_authorized_keys')) {
    if (Test-Path $f) {
      $c = Get-Content -Path $f -ErrorAction SilentlyContinue
      if (@($c | Where-Object { $_ -match 'workbuddy-hos-winvm-tunnel|wb-tunnel' }).Count -gt 0) { $found += $f }
    }
  }
  if ($found.Count -eq 0) { Ok '授权文件      ：已不含本通道公钥' }
  else { Warn ("授权文件      ：仍含本通道公钥 -> {0}" -f ($found -join '; ')) }

  # profile 的 authorized_keys：管理员账户走 Match 块，这个位置本就不写 -> 含公钥即"构建前遗留"
  $upf = ''
  $up = Get-UserProfileDir $User
  if ($up) {
    $uf = Join-Path (Join-Path $up '.ssh') 'authorized_keys'
    if (Test-Path $uf) {
      $c = Get-Content -Path $uf -ErrorAction SilentlyContinue
      if (@($c | Where-Object { $_ -match 'workbuddy-hos-winvm-tunnel|wb-tunnel' }).Count -gt 0) { $upf = $uf }
    }
  }
  if ($upf) {
    $bAk = @()
    try { if ($script:state -and $script:state.baseline -and $script:state.baseline.authFiles) { $bAk = @($script:state.baseline.authFiles) } } catch {}
    $preItem = @($bAk | Where-Object { $_.path -eq $upf }) | Select-Object -First 1
    $verdict = 'unknown'
    if ($preItem) {
      if ($null -ne $preItem.hasTunnelKey) {
        if ([bool]$preItem.hasTunnelKey) { $verdict = 'pre-existing' } else { $verdict = 'ours-leftover' }
      } elseif ($preItem.existed) {
        $verdict = 'pre-existing'
      }
    }
    switch ($verdict) {
      'pre-existing' { Detail ("授权文件      ：{0} 仍含本通道公钥 —— 构建前已存在（历史遗留，非本次写入）" -f $upf) }
      'ours-leftover' { Warn ("授权文件      ：{0} 仍含本通道公钥 —— 构建前不在，属本次写入未清干净（异常）" -f $upf) }
      default { Warn ("授权文件      ：{0} 仍含本通道公钥 —— journal 无该文件基线，无法判定来源" -f $upf) }
    }
  }

  # 5) 空密码网络登录策略
  $lbp = Get-LsaBlankPasswordPolicy
  $lbpTxt = '不存在(=默认1 禁止)'
  if ($null -ne $lbp) { $lbpTxt = [string]$lbp }
  Detail ("LimitBlankPasswordUse：{0}" -f $lbpTxt)

  # 6) 账本里还剩什么
  if ($script:state) {
    $pend = @($script:state.ops | Where-Object { [string]$_.undoState -eq 'pending' })
    if ($pend.Count -eq 0) { Ok 'journal       ：无 pending 项' }
    else { Warn ("journal       ：仍有 {0} 项 pending -> {1}" -f $pend.Count, (($pend | ForEach-Object { '#' + $_.id }) -join ',')) }
  }

  # 7) 临时文件残留（下载的安装包 / 预览副本 / 回滚副本）
  $tmpLeft = @()
  foreach ($p in @(
      (Join-Path $env:TEMP 'OpenSSH-Win64.msi'),
      (Join-Path $env:TEMP 'OpenSSH-Win64.zip'),
      (Join-Path $env:TEMP 'sshd_config.preview'),
      (Join-Path $env:TEMP 'wb-dryrun-base.conf'),
      (Join-Path $env:TEMP 'wb-base-min.conf'),
      (Join-Path $env:USERPROFILE 'wb-rollback.ps1'),
      (Join-Path $env:USERPROFILE 'Downloads\wb-rollback.ps1')
    )) {
    if ($p -and (Test-Path $p)) { $tmpLeft += $p }
  }
  foreach ($d in @(Get-ChildItem -Path $env:TEMP -Directory -Filter 'openssh-extract-*' -ErrorAction SilentlyContinue)) {
    $tmpLeft += $d.FullName
  }
  if ($tmpLeft.Count -eq 0) { Ok '临时文件      ：无残留' }
  else { Warn ("临时文件      ：仍有 {0} 个 -> {1}" -f $tmpLeft.Count, ($tmpLeft -join '; ')) }
  Detail '（构建/回滚日志 wb-tunnel-*.log 与 wb-msi-install-*.log 属审计留档，按设计保留）'
  Say ''
}

function Restore-WidenedBlankLogon {
  # 配置自洽：本次不放开空密码（EmptyUsed != yes），但账本里还留着"此前把
  # LimitBlankPasswordUse 改成 0"的记录 -> 就地收回。
  # 不收回的后果：sshd 层被 PermitEmptyPasswords no 挡住，LSA 层却仍"允许空密码网络登录"，
  # 等于少挡一层；哪天有人把 PermitEmptyPasswords 改回 yes，就直接退化成 none 匿名登录。
  # 只撤"本账本自己放宽的"（有 before 记录），别处设的 0 一律不碰。
  if (-not $script:state -or -not $script:state.ops) { return }
  if ([string]$script:EmptyUsed -eq 'yes') { return }
  $cur = Get-LsaBlankPasswordPolicy
  if ($null -eq $cur -or $cur -ne 0) { return }   # 已经是 1 或值不存在（=默认禁止），无需处理
  $ops = @($script:state.ops | Where-Object {
      [string]$_.action -eq 'allow-blank-network-logon' -and [string]$_.undoState -eq 'pending'
    })
  if ($ops.Count -eq 0) {
    Warn 'LimitBlankPasswordUse=0，但不是本账本放宽的（可能来自更早的构建或别的工具）-> 不擅自改，仅提示'
    return
  }
  foreach ($op in $ops) {
    try {
      $res = Invoke-Undo -Op $op
      $op.undoState  = 'done'
      $op.undoTs     = (Get-Date).ToString('o')
      $op.undoResult = [string]$res
      Save-WbState $script:state
      Ok ('已收回空密码网络登录放宽（配置自洽）：' + [string]$res)
    } catch {
      Warn ('收回 LimitBlankPasswordUse 失败：' + ($_.Exception.Message -split "`n")[0] + '（可稍后 -Rollback 重试）')
    }
  }
}

function Invoke-Rollback {
  Say ''
  Say '================================================================' 'White'
  Say ' 回滚模式（-Rollback）：按 journal 逆序撤销，精确还原到构建前' 'White'
  Say '================================================================' 'White'

  $st = Read-WbState
  if (-not $st) {
    Warn ("找不到 journal：{0}" -f $StateFile)
    Warn '说明：从未成功构建过，或已被完整清理 —— 当前无需操作。'
    return
  }

  $ops = @($st.ops)
  Info ("journal：{0}" -f $StateFile)
  Detail ("createdAt={0}  status={1}  buildCount={2}  ops={3}" -f $st.createdAt, $st.status, $st.buildCount, $ops.Count)
  if ($st.params) {
    $ks = [string]$st.params.publicKeySha256
    Detail ("params：user={0} port={1} harden={2} keySha={3}" -f $st.params.user, $st.params.port, $st.params.harden, $ks.Substring(0, [Math]::Min(16, $ks.Length)))
  }
  if ($st.baseline) {
    Detail ("baseline：sshd存在={0} 配置存在={1} capability={2}" -f $st.baseline.sshdServiceExisted, $st.baseline.configExisted, $st.baseline.capability)
  }
  if ([string]$st.status -eq 'rolledback') {
    Ok '该账本已标记为「已回滚」—— 仍逐条核对，只补未完成的项（幂等，不会重复动手）'
  }
  Say ''
  Info ("共 {0} 条操作，按逆序撤销（后做的先撤）" -f $ops.Count)

  $sum = [ordered]@{ total = $ops.Count; done = 0; skipped = 0; kept = 0; failed = 0; notes = @() }

  for ($i = $ops.Count - 1; $i -ge 0; $i--) {
    $op = $st.ops[$i]
    $pos = $ops.Count - $i
    Say ''
    Say ("--- [{0}/{1}] #{2} {3}（stage {4}: {5}）" -f $pos, $ops.Count, $op.id, $op.action, $op.stage, $op.stageName) 'Cyan'
    if ($op.before) { Detail ('before: ' + ($op.before | ConvertTo-Json -Compress -Depth 4)) }
    if ($op.after)  { Detail ('after : ' + ($op.after  | ConvertTo-Json -Compress -Depth 4)) }

    $u = $op.undo
    if (-not $u) {
      Detail '本步未实际改动（undo=none），无需撤销'
      $sum.skipped++
      continue
    }
    if ([string]$op.undoState -eq 'done') {
      Ok '上次已撤销完成 -> 跳过（幂等）'
      Detail ('undoResult: ' + [string]$op.undoResult)
      $sum.skipped++
      continue
    }
    $t = [string]$u.type
    if ($KeepService -and $t -eq 'uninstall_openssh') {
      Warn '-KeepService：保留 sshd 程序与服务，跳过卸载'
      if (-not $dryRunMode) {
        $op.undoState = 'kept'
        $op.undoTs = (Get-Date).ToString('o')
        $op.undoResult = 'skipped by -KeepService'
        Save-WbState $st
      }
      $sum.kept++
      continue
    }
    if ($dryRunMode) {
      Detail ('[DryRun] 将执行 undo:' + $t)
      Detail ('[DryRun] 参数：' + ($u | ConvertTo-Json -Compress -Depth 4))
      $sum.skipped++
      continue
    }

    try {
      $res = Invoke-Undo -Op $op
      $op.undoState  = 'done'
      $op.undoTs     = (Get-Date).ToString('o')
      $op.undoResult = [string]$res
      Save-WbState $st
      Ok ('已撤销：' + [string]$res)
      $sum.done++
    } catch {
      $msg = ($_.Exception.Message -split "`n")[0]
      $op.undoState  = 'failed'
      $op.undoTs     = (Get-Date).ToString('o')
      $op.undoResult = [string]$msg
      Save-WbState $st
      Warn ('撤销失败（继续处理其余项，稍后可重跑本命令只补失败项）：' + $msg)
      $sum.failed++
      $sum.notes += ('#{0} {1}: {2}' -f $op.id, $op.action, $msg)
    }
  }

  $cleaned = 0
  if (-not $dryRunMode) { $cleaned = Clear-TempLeftovers }

  Say ''
  Say '---------------- 回滚汇总 ----------------' 'White'
  Detail ("total={0}  done={1}  skipped(已撤/无改动)={2}  kept={3}  failed={4}  tempCleaned={5}" -f $sum.total, $sum.done, $sum.skipped, $sum.kept, $sum.failed, $cleaned)

  if ($dryRunMode) {
    Say ''
    Warn '这是 DryRun：以上只是计划，未做任何改动，journal 也未更新。'
    Warn '去掉 -DryRun 再执行即为真实回滚。'
    return
  }

  $st.rollbacks = @($st.rollbacks) + @([ordered]@{
    ts          = (Get-Date).ToString('o')
    keepService = [bool]$KeepService
    total       = $sum.total
    done        = $sum.done
    skipped     = $sum.skipped
    kept        = $sum.kept
    failed      = $sum.failed
    notes       = @($sum.notes)
    tempCleaned = $cleaned
  })
  $st.updatedAt = (Get-Date).ToString('o')
  if ($sum.failed -eq 0) { $st.status = 'rolledback' } else { $st.status = 'partial' }
  Save-WbState $st

  # 一次性计划任务（destroy-tunnel.sh 建的）也是残留
  try { & schtasks.exe /Delete /TN 'WbTunnelRollback' /F *>&1 | Out-Null } catch {}

  Show-RollbackResiduals -KeptService ([bool]$KeepService)

  Say ''
  if ($sum.failed -eq 0) {
    Ok '回滚完成：环境已回到构建前（账本保留供审计，status=rolledback）'
    Detail ("账本：{0}" -f $StateFile)
    Detail '下次构建会把它归档为 wb-tunnel-state.history-<ts>.json 后重开，不会新旧混账'
  } else {
    Err ("回滚未完全成功：{0} 项失败（status=partial）" -f $sum.failed)
    foreach ($n in $sum.notes) { Detail ('失败项：' + $n) }
    Warn '直接再跑一次 -Rollback 即可：已完成的项会自动跳过，只补失败项（幂等）。'
  }

  Say ''
  Info '宿主机侧验证（回滚后应重新不可达 / 连接被拒）：'
  Say '   sh ~/.workbuddy/skills/winvm-plugin-deploy/scripts/verify-tunnel.sh 172.16.100.2 User' 'White'
  Say ''
  Info '如需继续检查当前状态：'
  $selfHint = $script:SelfPathFinal
  if (-not $script:SelfStaged) { $selfHint = '<oneclick 脚本路径（本脚本未落盘，请先下载）>' }
  Say ('   powershell -NoProfile -ExecutionPolicy Bypass -File "' + $selfHint + '" -Continue') 'White'
  Say ''
}

# =====================================================================
#  -Continue 体检（只读）
# =====================================================================
function Show-Diagnostics {
  $script:StageTotal = 15
  $script:StageIdx = 0
  $verdict = @()

  Say ''
  Say '================================================================' 'White'
  Say ' 体检模式（-Continue）：只读诊断，不修改任何系统设置' 'White'
  Say '================================================================' 'White'

  # 1 环境
  Enter-Stage '环境与权限'
  Detail ("时间      ：{0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
  Detail ("计算机    ：{0}    用户上下文：{1}" -f $env:COMPUTERNAME, $env:USERNAME)
  $osName = ''
  try { $osName = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $osName = [string]$PSVersionTable.OS }
  Detail ("系统      ：{0}" -f $osName)
  Detail ("PowerShell：{0}   管理员：{1}" -f $PSVersionTable.PSVersion, $script:IsAdmin)
  Detail ("脚本      ：{0}  v{1}" -f $script:SelfPath, $SCRIPT_VERSION)
  Detail ("目标      ：{0}@{1}:{2}" -f $User, $env:COMPUTERNAME, $Port)
  if (-not $script:IsAdmin) { Warn '非管理员：事件日志/ACL 等检查可能被拒，结果仅供参考' }
  Exit-Stage

  # 2 sshd 服务
  Enter-Stage 'sshd 服务'
  $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if ($svc) {
    $svc.Refresh()
    Ok ("服务存在    ：Status={0} / StartType={1}" -f $svc.Status, $svc.StartType)
    try {
      $wmi = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop
      Detail ("PathName    ：{0}" -f $wmi.PathName)
      Detail ("ProcessId   ：{0}   State={1}" -f $wmi.ProcessId, $wmi.State)
    } catch {}
  } else {
    Warn '服务不存在（sshd 未安装 / 已被回滚卸载）'
    $verdict += 'sshd 未安装'
  }
  Exit-Stage

  # 3 sshd.exe 与版本
  Enter-Stage 'sshd.exe'
  $exe = Get-SshdExe
  $vok = $false
  if ($exe -and (Test-Path $exe)) {
    Ok ("路径        ：{0}" -f $exe)
    try {
      $v = & $exe -V 2>&1 | Out-String
      Detail ("版本        ：{0}" -f ($v.Trim() -replace "`r?`n", ' '))
    } catch { Detail '版本查询失败（sshd -V 需要可执行权限）' }
    $vok = $true
    $pc = Get-OpenSshMsiProductCode
    if ($pc) { Detail ("安装来源    ：MSI（ProductCode={0}）" -f $pc) }
    elseif (Test-Path 'C:\Program Files\OpenSSH\Install-sshd.ps1') { Detail '安装来源    ：zip（C:\Program Files\OpenSSH\Install-sshd.ps1 存在）' }
    elseif ($exe -like 'C:\Windows\System32\OpenSSH*') { Detail '安装来源    ：Windows 可选功能（System32\OpenSSH）' }
  } else {
    Warn '未找到 sshd.exe（C:\Windows\System32\OpenSSH 或 C:\Program Files\OpenSSH）'
  }
  Exit-Stage

  # 4 配置关键项
  Enter-Stage 'sshd_config 关键项'
  if (Test-Path $SSHD_CFG) {
    Ok ("配置存在    ：{0}" -f $SSHD_CFG)
    Detail ("sha256      ：{0}" -f (Get-FileShaSafe $SSHD_CFG))
    if (Test-Path $OrigBak) { Detail ("原始留档    ：{0}（destroy 用它还原）" -f $OrigBak) }
    else { Detail '原始留档    ：无（说明构建前 sshd_config 不存在）' }
    $pat = '^\s*(Port|ListenAddress|PubkeyAuthentication|PasswordAuthentication|PermitEmptyPasswords|PermitRootLogin|MaxAuthTries|LoginGraceTime|Match|AuthorizedKeysFile)\b'
    $hit = 0
    foreach ($l in (Select-String -Path $SSHD_CFG -Pattern $pat -ErrorAction SilentlyContinue)) {
      Detail ("  " + $l.Line.Trim()); $hit++
    }
    if ($hit -eq 0) { Warn '没有读到任何关键指令（配置可能是空的/全被注释）' }
  } else {
    Warn ("配置不存在：{0}" -f $SSHD_CFG)
    $verdict += 'sshd_config 缺失'
  }
  Exit-Stage

  # 5 配置语法
  Enter-Stage 'sshd -t 语法校验'
  if ($vok) {
    $out = & $exe -t 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
      Ok '配置语法 OK（sshd -t exit=0）'
      if ($out.Trim()) { Detail $out.Trim() }
    } else {
      Err ("配置语法错误（exit={0}）：{1}" -f $LASTEXITCODE, ($out.Trim() -replace "`r?`n", ' | '))
      $verdict += 'sshd_config 语法错误'
    }
  } else {
    Warn '跳过：没有 sshd.exe'
  }
  Exit-Stage

  # 6 端口监听
  Enter-Stage ('端口监听 TCP {0}' -f $Port)
  $listenOk = $false
  try {
    $lst = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    if ($lst.Count -gt 0) {
      $listenOk = $true
      foreach ($c in $lst) {
        $pname = ''
        try { $pname = (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch {}
        Ok ("监听中      ：{0}:{1}  pid={2}（{3}）" -f $c.LocalAddress, $c.LocalPort, $c.OwningProcess, $pname)
        if ($pname -and $pname -ne 'sshd') { Warn ("监听者不是 sshd 而是 {0} —— 端口被占用" -f $pname) }
      }
    } else {
      Warn ("没有进程监听 TCP {0}" -f $Port)
    }
  } catch {
    Warn ("Get-NetTCPConnection 失败：{0}" -f ($_.Exception.Message -split "`n")[0])
    try {
      $n = @(netstat -ano | Select-String (':' + $Port + '\s') | Select-String 'LISTENING')
      if ($n.Count -gt 0) {
        $listenOk = $true
        foreach ($x in $n) { Detail ('netstat: ' + $x.Line.Trim()) }
      }
    } catch {}
  }
  if (-not $listenOk -and $svc) { $verdict += '服务在但端口未监听' }
  Exit-Stage

  # 7 网络配置档
  Enter-Stage '网络配置档'
  $publicCount = 0
  try {
    foreach ($p in @(Get-NetConnectionProfile -ErrorAction Stop)) {
      $mark = 'OK'
      if ([string]$p.NetworkCategory -eq 'Public') { $mark = 'Public(会挡端口)'; $publicCount++ }
      Detail ("{0}  alias={1}  category={2}  [{3}]" -f $p.Name, $p.InterfaceAlias, $p.NetworkCategory, $mark)
    }
    if ($publicCount -gt 0) { Warn ("有 {0} 个配置档是 Public：系统预置防火墙规则在该档下不生效，TCP 会被静默丢弃" -f $publicCount) }
  } catch { Warn ("读取失败：{0}" -f ($_.Exception.Message -split "`n")[0]) }
  try {
    foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '127.*' })) {
      Detail ("本机 IPv4    ：{0}/{1}  ({2})" -f $ip.IPAddress, $ip.PrefixLength, $ip.InterfaceAlias)
    }
  } catch {}
  Exit-Stage

  # 8 防火墙
  Enter-Stage '防火墙规则'
  $anyAllow  = $false
  $anySource = $false
  foreach ($n in @('OpenSSH-Server-In-TCP', 'OpenSSH-Server-In-TCP-WB')) {
    $fw = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
    if (-not $fw) {
      Warn ("{0}：不存在" -f $n)
      continue
    }
    $pfPort = ''
    try { $pfPort = [string]($fw | Get-NetFirewallPortFilter -ErrorAction Stop).LocalPort } catch {}
    $pr = [string]$fw.Profile
    $en = [bool]$fw.Enabled
    $ac = [string]$fw.Action
    $rem = ''
    try { $rem = (@((($fw | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress)) -join ',') } catch {}
    if ($en -and $pr -match 'Any' -and $ac -eq 'Allow') {
      $anyAllow = $true
      if ($rem -match '(^|,)Any(,|$)') { $anySource = $true }
    }
    Detail ("{0}：Enabled={1} Profile={2} Action={3} Port={4} Remote={5}" -f $n, $en, $pr, $ac, $pfPort, $(if($rem){$rem}else{'?'}))
  }
  try {
    foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
      Detail ("配置档 {0}：Enabled={1}  InboundDefault={2}" -f $p.Name, $p.Enabled, $p.DefaultInboundAction)
    }
  } catch {}
  if (-not $anyAllow) { $verdict += '没有 Profile=Any 的放行规则' }
  if ($anyAllow -and $anySource) { $verdict += '防火墙对任意来源放行（未限定 -AllowFrom）' }
  Exit-Stage

  # 9 授权文件与 ACL
  Enter-Stage '授权文件与 ACL'
  $ourKeyOk = $false
  $stForBlob = Read-WbState
  $blob = ''
  if ($stForBlob -and $stForBlob.params) { $blob = [string]$stForBlob.params.publicKeyBlob }
  if (-not $blob -and $PublicKey -match '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)') { $blob = ($PublicKey -split '\s+')[1] }
  $files = @(
    'C:\ProgramData\ssh\administrators_authorized_keys',
    (Join-Path (Join-Path (Get-UserProfileDir $User) '.ssh') 'authorized_keys')
  )
  foreach ($f in $files) {
    if (Test-Path $f) {
      $lines = @(Get-Content -Path $f -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
      $has = $false
      if ($blob) { $has = [bool](@($lines | Where-Object { $_.Contains($blob) }).Count -gt 0) }
      if ($has) { $ourKeyOk = $true }
      Ok ("{0}  行数={1}  含本通道公钥={2}" -f $f, $lines.Count, $has)
      try {
        $aclOut = & icacls.exe $f 2>&1 | Out-String
        Detail ('ACL: ' + (($aclOut -split "`r?`n" | Where-Object { $_.Trim() }) -join ' ; '))
      } catch {}
    } else {
      Detail ("{0}：不存在" -f $f)
    }
  }
  if (-not $blob) {
    Detail '（无法确定本通道公钥：既没有账本、也未传入合法公钥 -> 跳过"含公钥"判定）'
  } elseif (-not $ourKeyOk) {
    $verdict += '授权文件里找不到本通道公钥'
  }
  Exit-Stage

  # 10 账户策略
  Enter-Stage ('账户 {0} 状态' -f $User)
  try {
    $lu = Get-LocalUser -Name $User -ErrorAction Stop
    Ok ("存在        ：{0}   Enabled={1}   PasswordRequired={2}" -f $lu.Name, $lu.Enabled, $lu.PasswordRequired)
    Detail ("PasswordLastSet：{0}   LastLogon：{1}" -f $(if ($lu.PasswordLastSet) { $lu.PasswordLastSet } else { 'never' }), $(if ($lu.LastLogon) { $lu.LastLogon } else { 'never' }))
    Detail '（只读策略位；本脚本从不修改账户密码）'
    $lbp = Get-LsaBlankPasswordPolicy
    $lbpTxt = '不存在(=系统默认1，禁止空密码网络登录)'
    if ($null -ne $lbp) { $lbpTxt = [string]$lbp }
    Detail ("LimitBlankPasswordUse：{0}   （0=允许空密码网络登录；1/默认=禁止）" -f $lbpTxt)
    Detail '（本脚本仅在 -EmptyPasswordMode 判定为 yes 时把它改为 0，并记 journal 可还原）'
    try {
      $grpName = (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name
      $inAdmin = @(Get-LocalGroupMember -Group $grpName -ErrorAction Stop | ForEach-Object { $_.Name }) |
                 Where-Object { $_ -eq $User -or $_ -match ('\\' + [regex]::Escape($User) + '$') }
      Detail ("属管理员组  ：{0}（决定公钥落在 ProgramData 还是用户 profile）" -f [bool]$inAdmin)
    } catch {}
  } catch { Warn ("无法读取账户：{0}" -f ($_.Exception.Message -split "`n")[0]) }
  Exit-Stage

  # 11 安装器占用 / 待重启（msiexec 1618/1603 的诊断入口）
  Enter-Stage 'Windows Installer 占用 / 待重启标记'
  try {
    $pd = Test-PendingReboot
    if ($pd) { Warn ("待重启标记：{0}（CBS=DISM 残留 / WU=Windows Update）-> msiexec 会报 1618/1603；建议重启 VM 后再装" -f $pd) }
    else { Ok '无 CBS/WU 待重启标记（可安全安装）' }
    $pfc = Get-PfroCount
    if ($pfc -gt 0) {
      Detail ("PFRO 队列：{0} 条（PendingFileRenameOperations）" -f $pfc)
      Detail '  ↑ 正常现象：下次启动才执行的改名/删除清单，不影响安装，无进程可结束，无需处理'
    } else { Detail 'PFRO 队列：空' }
    $msv = Get-Service -Name msiserver -ErrorAction SilentlyContinue
    if ($msv) { Detail ("服务 msiserver：{0} / {1}" -f $msv.Status, $msv.StartType) } else { Detail '服务 msiserver：不存在' }
    # msiexec.exe 常驻进程通常只是 MSI 服务宿主（msiserver 起来后就有），
    # 真正"有安装在进行"的唯一可靠判据是全局互斥体 Global\_MSIExecute 是否存在。
    $msiBusy = $false
    try {
      $mtx = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
      $msiBusy = $true
      $mtx.Dispose()
    } catch { $msiBusy = $false }
    $mp = @(Get-Process -Name msiexec -ErrorAction SilentlyContinue)
    if ($msiBusy) {
      Warn '检测到 Global\_MSIExecute 互斥体 -> 当前确实有 MSI 安装在进行，现在装会报 1618'
    } elseif ($mp.Count -gt 0) {
      Detail ("msiexec 进程 {0} 个（MSI 服务宿主，属正常；未持有安装互斥体 -> 不会 1618）" -f $mp.Count)
    } else {
      Ok '无 msiexec 进程（安装器空闲，不会 1618）'
    }
    $ti = @(Get-Process -Name TrustedInstaller -ErrorAction SilentlyContinue)
    Detail ("TrustedInstaller 进程：{0} 个（CBS 服务，常驻属正常；勿强杀）" -f $ti.Count)
  } catch { Warn ("读取失败：{0}" -f ($_.Exception.Message -split "`n")[0]) }
  Exit-Stage

  # 12 事件日志
  Enter-Stage '事件日志（最近 8 条）'
  $got = $false
  foreach ($ln in @('OpenSSH/Operational', 'OpenSSH/Admin')) {
    try {
      $evs = @(Get-WinEvent -LogName $ln -MaxEvents 8 -ErrorAction Stop)
      if ($evs.Count -gt 0) {
        $got = $true
        Ok ("日志 {0}：" -f $ln)
        foreach ($e in $evs) {
          $msg = ''
          try { $msg = (([string]$e.Message) -split "`n")[0] } catch { $msg = '' }
          Detail ("{0}  [{1}] {2}" -f $e.TimeCreated.ToString('MM-dd HH:mm:ss'), $e.LevelDisplayName, $msg.Trim())
        }
      }
    } catch {
      Detail ("{0}：不可读（{1}）" -f $ln, ($_.Exception.Message -split "`n")[0])
    }
  }
  if (-not $got) { Detail '没有可读的 OpenSSH 事件日志（sshd 可能从未启动过）' }
  try {
    $sysEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddHours(-2) } -MaxEvents 40 -ErrorAction Stop |
               Where-Object { ([string]$_.Message) -match 'sshd' })
    if ($sysEv.Count -gt 0) {
      Ok 'System 日志中与 sshd 服务相关的记录：'
      foreach ($e in ($sysEv | Select-Object -First 6)) {
        Detail ("{0}  [{1}] {2}" -f $e.TimeCreated.ToString('MM-dd HH:mm:ss'), $e.LevelDisplayName, (([string]$e.Message) -split "`n")[0].Trim())
      }
    }
  } catch {}
  Exit-Stage

  # 13 journal 状态
  Enter-Stage 'journal 状态'
  $st = Read-WbState
  if (-not $st) {
    Detail ("不存在：{0}" -f $StateFile)
    Detail '说明：从未构建过，或账本已被清理'
  } else {
    Ok ("存在        ：{0}   status={1}   ops={2}" -f $StateFile, $st.status, @($st.ops).Count)
    Detail ("createdAt={0}  buildCount={1}  最近更新={2}" -f $st.createdAt, $st.buildCount, $st.updatedAt)
    if ($st.params) { Detail ("params：user={0} port={1} harden={2}" -f $st.params.user, $st.params.port, $st.params.harden) }
    $tail = @(@($st.ops) | Select-Object -Last 5)
    if ($tail.Count -gt 0) {
      Ok '最近 5 条操作：'
      foreach ($o in $tail) {
        $ut = '-'
        if ($o.undo) { $ut = [string]$o.undo.type }
        Detail ("#{0} {1}  result={2}  undo={3}  undoState={4}" -f $o.id, $o.action, $o.result, $ut, $o.undoState)
      }
    }
    if ($st.rollbacks) {
      $last = @(@($st.rollbacks) | Select-Object -Last 1)
      if ($last.Count -gt 0) {
        Detail ("最近回滚：{0}  done={1} failed={2} skipped={3}" -f $last[0].ts, $last[0].done, $last[0].failed, $last[0].skipped)
      }
    }
  }
  Exit-Stage

  # 14 回环连通性
  Enter-Stage '本机回环连通性'
  $loop = Test-Tcp -Target '127.0.0.1' -TcpPort $Port -TimeoutMs 1500
  if ($loop) { Ok ("127.0.0.1:{0} 可连（进程在监听，TCP 层通）" -f $Port) }
  else { Warn ("127.0.0.1:{0} 连不上（服务没监听，或只绑定了别的地址）" -f $Port) }
  try {
    foreach ($b in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $Port })) {
      Detail ("绑定地址：{0}" -f $b.LocalAddress)
    }
  } catch {}
  Exit-Stage

  # 15 结论
  Enter-Stage '结论与建议'
  $svcRunning = ($svc -and $svc.Status -eq 'Running')
  if (-not $svc) {
    Err '结论：sshd 未安装 —— 通道尚未构建，或已被 -Rollback 卸载。'
    Say '    下一步：以管理员执行 build：' 'Yellow'
    Say ('      powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script:SelfPathFinal + '"') 'White'
  } elseif (-not $svcRunning) {
    Err ("结论：服务存在但状态是 {0} —— 没在跑。" -f $svc.Status)
    Say '    下一步：Start-Service sshd；若起不来，看第 11 项事件日志的错误码。' 'Yellow'
  } elseif (-not $listenOk) {
    Err '结论：服务 RUNNING 但端口没监听 —— 配置或启动失败。'
    Say '    下一步：看第 5 项（sshd -t）和第 11 项（事件日志）；常见是 Port 冲突或 HostKey 缺失。' 'Yellow'
  } elseif ($publicCount -gt 0 -and -not $anyAllow) {
    Warn '结论：服务正常，但网络档是 Public 且没有 Profile=Any 放行规则 —— 外部连 22 会超时（DROP）。'
    Say '    下一步：重跑 build（会自动改 Private 并补 Any 规则），或手工修。' 'Yellow'
  } elseif ($publicCount -gt 0) {
    Warn '结论：服务正常、有 Any 放行规则，但网络档仍是 Public —— 通常可用，建议改 Private 更稳。'
    Say '    下一步：Set-NetConnectionProfile -InterfaceAlias "<别名>" -NetworkCategory Private' 'Yellow'
  } elseif ($blob -and -not $ourKeyOk) {
    Warn '结论：服务与端口都正常，但授权文件里找不到本通道公钥 —— 登录会被拒。'
    Say '    下一步：重跑 build（会自动写公钥并收紧 ACL）。' 'Yellow'
  } else {
    Ok '结论：VM 侧看起来就绪（服务 RUNNING + 端口监听 + 规则到位 + 公钥在位）。'
    Say '    下一步：回宿主机验证：' 'Yellow'
    Say '      sh ~/.workbuddy/skills/winvm-plugin-deploy/scripts/verify-tunnel.sh 172.16.100.2 User' 'White'
  }
  if ($verdict.Count -gt 0) {
    Say ''
    Warn ('发现的问题：' + ($verdict -join ' / '))
  }
  Exit-Stage

  Say ''
  Info ("体检结束。完整报告：{0}" -f $script:LogFile)
  Say '   把上面这段（或该文件内容）整段复制回来即可分析。' 'Yellow'
  Say ''
}

# =====================================================================
#  安装层
# =====================================================================
function Test-PendingReboot {
  # 只返回"真·阻塞安装"的待重启标记：
  #   CBS = Component Based Servicing（DISM/可选功能残留）-> 会让 msiexec 报 1618/1603
  #   WU  = Windows Update 待重启
  # 注意：PendingFileRenameOperations（PFRO）**故意不算**。它是"下次启动时再改名/删除"的
  # 文件队列，几乎所有安装/卸载都会留下、常驻不清，且在下次启动前不影响 msiexec。
  # 早期版本把 PFRO 一起报成"挂起操作"，造成误报（v2.1.2 修正）。
  $hit = @()
  try {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $hit += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $hit += 'WU' }
  } catch {}
  return ($hit -join ',')
}

function Get-PfroCount {
  # PFRO（PendingFileRenameOperations）条目数：纯信息展示，不参与判定
  try {
    $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($v) { return @($v).Count }
  } catch {}
  return 0
}

function Get-OpenSshMsiProductCode {
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $hit = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -and $_.DisplayName -match '(?i)OpenSSH' } | Select-Object -First 1
    if ($hit) {
      $code = [string]$hit.PSChildName
      if ($code -match '^\{[0-9A-Fa-f-]{36}\}$') { return $code }
    }
  }
  return ''
}

function Get-GhPrefixes {
  # 顺序按 2026-11-09 实测（前 4MB 速度，宿主机侧同网段）重排，快的在前：
  #   gh-proxy.com   5.92 MB/s   <- 首选
  #   ghfast.top     1.01 MB/s
  #   ghproxy.net    0.03 MB/s   <- 兜底（很慢）
  #   github.com     直连 HEAD 200，但 GET 常被限速/超时
  # 已剔除实测不通、只会白等 8s 的源：mirror.ghproxy.com / hub.gitmirror.com /
  #   gh.llkk.cc / github.moeyy.xyz / ghproxy.cc
  # 若你本地实测另有更快的源，直接用 -DownloadUrl 指定即可（优先级最高）。
  return @(
    'https://gh-proxy.com/https://github.com/'
    'https://ghfast.top/https://github.com/'
    'https://ghproxy.net/https://github.com/'
    'https://github.com/'
  )
}

function Get-MsiUrlCandidates {
  $rels = @(
    @{ tag = '10.4.0.0p1-Preview';  file = 'OpenSSH-Win64-v10.4.0.0.msi' },
    @{ tag = 'v10.4.0.0p1-Preview'; file = 'OpenSSH-Win64-v10.4.0.0.msi' },
    @{ tag = 'v10.4.0.0p1-Beta';    file = 'OpenSSH-Win64-v10.4.0.0.msi' },
    @{ tag = 'v9.5.0.0p1-Beta';     file = 'OpenSSH-Win64-v9.5.0.0.msi' }
  )
  $out = New-Object 'System.Collections.Generic.List[string]'
  # 用户自定义源最优先（速度/可用性由用户自己掌握）
  if ($DownloadUrl) { $out.Add($DownloadUrl) }
  foreach ($r in $rels) {
    $path = 'PowerShell/Win32-OpenSSH/releases/download/{0}/{1}' -f $r.tag, $r.file
    foreach ($p in (Get-GhPrefixes)) { $out.Add($p + $path) }
  }
  return $out
}

function Test-UrlReachable {
  param([string]$Url, [int]$TimeoutSec = 6)
  try {
    $a = @{ Uri = $Url; Method = 'Head'; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($script:ProxyUrl) { $a['Proxy'] = $script:ProxyUrl }
    $r = Invoke-WebRequest @a
    return ([int]$r.StatusCode -ge 200 -and [int]$r.StatusCode -lt 400)
  } catch {
    # 有些 CDN 不允许 HEAD（405）但 GET 可用 -> 再用 Range GET 探一次
    try {
      $a2 = @{ Uri = $Url; Method = 'Get'; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop'
               Headers = @{ Range = 'bytes=0-0' } }
      if ($script:ProxyUrl) { $a2['Proxy'] = $script:ProxyUrl }
      $r2 = Invoke-WebRequest @a2
      return ([int]$r2.StatusCode -ge 200 -and [int]$r2.StatusCode -lt 400)
    } catch { return $false }
  }
}

function Save-FileFromUrl {
  param([string]$Url, [string]$OutFile, [string]$Magic = '')
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if (Test-Path $OutFile) { Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue }
  $ha = @{ Uri = $Url; OutFile = $OutFile; UseBasicParsing = $true; TimeoutSec = $DownloadTimeoutSec; ErrorAction = 'Stop' }
  if ($script:ProxyUrl) { $ha['Proxy'] = $script:ProxyUrl }
  Invoke-WebRequest @ha
  $sw.Stop()
  if (-not (Test-Path $OutFile)) { throw '下载后文件不存在' }
  $mb = (Get-Item $OutFile).Length / 1MB
  if ($mb -lt 0.5) { throw ("文件异常偏小（{0:N2} MB），疑似错误页" -f $mb) }
  if ($Magic) {
    # Magic 是十六进制串，2 个字符 = 1 字节。旧版直接把它当"字节数"用，
    # 导致 'D0CF11E0' 读成 8 字节 -> 得到 D0CF11E0A1B11AE1 -> 恒不等于 'D0CF11E0'，
    # 把下载成功的正常包全判成"错误页"（v2.1.3 修正）。
    $m = ($Magic.ToUpper() -replace '[^0-9A-F]', '')
    $nbyte = [int]($m.Length / 2)
    $buf = New-Object byte[] $nbyte
    $fs = [System.IO.File]::OpenRead($OutFile)
    try { $got = $fs.Read($buf, 0, $nbyte) } finally { $fs.Close() }
    $hex = (($buf[0..([Math]::Max(0, $got - 1))] | ForEach-Object { $_.ToString('X2') }) -join '')
    if (-not $hex.StartsWith($m)) { throw ("文件头不匹配（{0} != {1}），疑似错误页/防劫持页" -f $hex, $m) }
    Detail ("文件头校验通过：{0}" -f $hex)
  }
  Ok ("下载完成 {0:N1} MB，用时 {1:N1}s" -f $mb, $sw.Elapsed.TotalSeconds)
  return $mb
}

function Install-MsiFile {
  param([string]$MsiPath)
  if (-not (Test-Path $MsiPath)) { throw ("msi 不存在：{0}" -f $MsiPath) }
  $mb = (Get-Item $MsiPath).Length / 1MB
  Info ("msiexec 静默安装 {0}（{1:N1} MB）..." -f (Split-Path -Leaf $MsiPath), $mb)
  Detail '预计 10-40 秒；此步界面完全无输出属正常，不要关窗口'
  try { Unblock-File -Path $MsiPath -ErrorAction SilentlyContinue } catch {}

  $msiLog = Join-Path $LogDir ('wb-msi-install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $code = -1
  for ($try = 1; $try -le 3; $try++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath 'msiexec.exe' `
      -ArgumentList @('/i', ('"{0}"' -f $MsiPath), '/qn', '/norestart', '/l*v', ('"{0}"' -f $msiLog)) `
      -Wait -PassThru -NoNewWindow
    $sw.Stop()
    $code = [int]$p.ExitCode
    Detail ("第 {0} 次 msiexec 退出码 = {1}（用时 {2:N1}s）" -f $try, $code, $sw.Elapsed.TotalSeconds)
    if ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641) { break }
    if ($code -eq 1618) {
      Warn '另一个安装/服务操作正在进行（1618）。等 15 秒重试（多半是刚才被中止的 Add-WindowsCapability 余波）'
      Start-Sleep -Seconds 15
      continue
    }
    break
  }

  switch ($code) {
    0    { Ok 'msiexec 安装成功（0）' }
    3010 { Ok 'msiexec 安装成功（3010 = 需重启生效，不阻塞本流程）' }
    1641 { Ok 'msiexec 安装成功并已请求重启（1641）' }
    1618 {
      $pd = Test-PendingReboot
      $extra = ''
      if ($pd) { $extra = "（当前存在待重启标记：$pd，这是主因）" }
      throw ("msiexec 1618：Windows Installer 正被占用$extra。两种处理：① 等 1-2 分钟后直接重跑本脚本（已内置 15s×3 重试，且 journal 会续上）；② 重启 VM 后重跑（最稳）。msi 日志：{0}" -f $msiLog)
    }
    1603 { throw ("msiexec 1603：致命错误（多为权限/磁盘/安装包损坏）。msi 日志：{0}" -f $msiLog) }
    default { throw ("msiexec 失败 exit={0}。msi 日志：{1}" -f $code, $msiLog) }
  }

  if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    Warn 'msi 装完但没看到 sshd 服务，尝试执行安装目录里的 Install-sshd.ps1'
    if (-not (Start-InstallSshdScript)) {
      throw ("msi 已安装但 sshd 服务仍未注册。到 {0} 手动运行 Install-sshd.ps1" -f 'C:\Program Files\OpenSSH')
    }
  }
  return $msiLog
}

function Install-ViaMsi {
  param([string]$LocalMsi)
  $MAGIC = 'D0CF11E0'   # OLE 复合文档头（.msi 必有）
  $MsiFile = ''

  if ($LocalMsi) {
    if (-not (Test-Path $LocalMsi)) { throw ("指定的 msi 不存在：{0}" -f $LocalMsi) }
    $MsiFile = $LocalMsi
    Info ("使用本地 msi：{0}" -f $MsiFile)
  } else {
    $MsiFile = Join-Path $env:TEMP 'OpenSSH-Win64.msi'
    $cands = @(Get-MsiUrlCandidates)
    Info ("候选下载地址 {0} 个（GitHub 直连 + 4 个加速镜像 × 4 个版本 tag）" -f $cands.Count)

    # 先做快速 HEAD 探测（8s），避免在不通的镜像上死等
    $pick = ''
    foreach ($u in $cands) {
      Detail ("探测：{0}" -f $u)
      if (Test-UrlReachable -Url $u) { $pick = $u; Ok ("可用源：{0}" -f $u); break }
      Detail '  不可用，换下一个'
    }
    if (-not $pick) {
      Warn 'HEAD 探测全部不可用，改为依次直连下载；再不行就查 GitHub API'
      foreach ($u in $cands) {
        try { Save-FileFromUrl -Url $u -OutFile $MsiFile -Magic $MAGIC | Out-Null; $pick = $u; break }
        catch { Warn ("失败：{0}" -f ($_.Exception.Message -split "`n")[0]) }
      }
    } else {
      try { Save-FileFromUrl -Url $pick -OutFile $MsiFile -Magic $MAGIC | Out-Null }
      catch {
        Warn ("选定源下载失败：{0}；改为查 GitHub API" -f ($_.Exception.Message -split "`n")[0])
        $pick = ''
      }
    }

    if (-not $pick) {
      try {
        Info '查询 GitHub API 拿最新 release 的 Win64 msi 真实地址 ...'
        $api = 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases'
        $ia = @{ Uri = $api; Headers = @{ 'User-Agent' = 'wb-tunnel' }; TimeoutSec = 30; ErrorAction = 'Stop' }
        if ($script:ProxyUrl) { $ia['Proxy'] = $script:ProxyUrl }
        $rels = Invoke-RestMethod @ia
        $url = ''
        foreach ($rel in $rels) {
          foreach ($a in $rel.assets) {
            if ($a.name -match '(?i)^OpenSSH-Win64-.*\.msi$') { $url = $a.browser_download_url; break }
          }
          if ($url) { break }
        }
        if ($url) {
          Ok ("API 给出地址：{0}" -f $url)
          Save-FileFromUrl -Url $url -OutFile $MsiFile -Magic $MAGIC | Out-Null
          $pick = $url
        }
      } catch {
        Warn ("GitHub API 也不可用：{0}" -f ($_.Exception.Message -split "`n")[0])
      }
    }

    if (-not $pick) {
      throw ("所有下载源都失败。请在能上网的机器下载 OpenSSH-Win64-v10.4.0.0.msi，拷到 VM 后用 -MsiPath 指定路径重跑；或用 -InstallMethod Zip。下载页：https://github.com/PowerShell/Win32-OpenSSH/releases")
    }
    $script:MsiSourceUrl = $pick
  }

  $script:MsiUsed = $MsiFile
  $msiLog = Install-MsiFile -MsiPath $MsiFile
  $script:MsiLogFile = $msiLog
  $script:InstallUsed = 'msi'
  $script:MsiProductCode = Get-OpenSshMsiProductCode
  if ($script:MsiProductCode) { Detail ("MSI ProductCode = {0}（destroy 用它静默卸载）" -f $script:MsiProductCode) }
  else { Warn '未取到 MSI ProductCode，destroy 将退回 Install-sshd.ps1/uninstall-sshd.ps1 + 删目录' }
  Ok 'OpenSSH Server 已通过 MSI 安装'
}

function Start-InstallSshdScript {
  foreach ($p in @('C:\Program Files\OpenSSH\Install-sshd.ps1', 'C:\Program Files\OpenSSH-Win64\Install-sshd.ps1')) {
    if (Test-Path $p) {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p *>&1 | Out-Null
      if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { return $true }
    }
  }
  return $false
}

function Install-ViaZip {
  param([string]$ZipPath)
  if ($ZipPath) {
    if (-not (Test-Path $ZipPath)) { throw "指定的 zip 不存在：$ZipPath" }
    Info ("使用本地 zip：{0}" -f $ZipPath)
  } else {
    # tag 用用户实测可行的 10.4.0.0p1-Preview，另有 v10.4/v9.5 兜底
    $rels = @(
      'PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-Win64.zip',
      'PowerShell/Win32-OpenSSH/releases/download/v10.4.0.0p1-Beta/OpenSSH-Win64.zip',
      'PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip'
    )
    $mirrors = @()
    if ($DownloadUrl) { $mirrors += $DownloadUrl }
    foreach ($r in $rels) { foreach ($p in (Get-GhPrefixes)) { $mirrors += ($p + $r) } }

    $ZipPath = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
    $got = $false
    $n = 0
    foreach ($u in $mirrors) {
      $n++
      try {
        Info ("下载 {0}/{1}：{2}" -f $n, $mirrors.Count, $u)
        Detail ("超时上限 {0}s；下载期间界面不动是正常的" -f $DownloadTimeoutSec)
        Save-FileFromUrl -Url $u -OutFile $ZipPath -Magic '504B0304' | Out-Null
        $got = $true
        break
      } catch {
        Warn ("下载失败：{0}" -f ($_.Exception.Message -split "`n")[0])
      }
    }
    if (-not $got) {
      throw '所有镜像均下载失败。请在能上网的机器下载 OpenSSH-Win64.zip，拷到 VM 后用 -OpenSSHZipPath 指定路径重跑。'
    }
  }

  $root = Join-Path $env:TEMP ('openssh-extract-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  Detail ("解压到 {0}" -f $root)
  Expand-Archive -Path $ZipPath -DestinationPath $root -Force -ErrorAction Stop
  $inner = Get-ChildItem -Path $root -Directory | Select-Object -First 1
  $src = $root
  if ($inner) { $src = $inner.FullName }
  $dst = 'C:\Program Files\OpenSSH'
  if (Test-Path $dst) { Remove-Item -Path $dst -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction Stop
  Detail '执行 Install-sshd.ps1 注册服务 ...'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'Install-sshd.ps1') *>&1 | Out-Null
  if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { throw 'Install-sshd.ps1 执行后仍未创建 sshd 服务' }
  $script:InstallUsed = 'zip'
  Ok ("Win32-OpenSSH 已安装 -> {0}" -f $dst)
}

function Install-ViaWinget {
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if (-not $wg) { Warn '未检测到 winget，跳过'; return $false }
  foreach ($id in @('Microsoft.OpenSSH.Preview', 'Microsoft.OpenSSH.Beta')) {
    try {
      Info ("winget 安装 {0} ..." -f $id)
      Detail '这一步可能需要 1-3 分钟，界面无输出属正常'
      & winget install --id $id --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity *>&1 | Out-Null
      if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        $script:InstallUsed = 'winget'
        Ok ("winget 安装成功：{0}" -f $id)
        return $true
      }
      if (Start-InstallSshdScript) {
        $script:InstallUsed = 'winget'
        Ok ("winget 安装成功并注册服务：{0}" -f $id)
        return $true
      }
      Warn 'winget 返回成功但服务仍未出现，继续尝试'
    } catch {
      Warn ("winget {0} 失败：{1}" -f $id, ($_.Exception.Message -split "`n")[0])
    }
  }
  return $false
}

function Ensure-OpenSSHServer {
  $sshdExeProbe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
  if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
    if (Test-Path $sshdExeProbe) {
      Ok 'sshd 服务已存在且二进制在位，跳过安装'
      return
    }
    # 服务壳还在、sshd.exe 却没了 —— 这是 OpenSSH.Server 能力被卸载后的残留
    # （-Rollback 撤 capability 时就会出现）。若这里跳过安装，
    # 阶段 3 的 Start-Service 必然报 "Cannot start service sshd"。
    Warn ('sshd 服务壳存在但 {0} 缺失（能力已被卸载的残留）→ 清壳重装' -f $sshdExeProbe)
    try { & sc.exe stop sshd 2>$null | Out-Null } catch {}
    try { & sc.exe delete sshd 2>$null | Out-Null } catch {}
    Detail '已移除失去二进制的服务壳，改走正常安装流程重新注册'
  }
  if ($SkipInstall) { throw '未检测到可用的 sshd 且指定了 -SkipInstall' }

  # 真的会阻塞 msiexec 的只有 CBS/WU 待重启标记；PFRO 只作信息展示（正常现象）
  $pending = Test-PendingReboot
  if ($pending) {
    Warn ("检测到待重启标记：{0}（DISM/Windows Update 的未完成事务）" -f $pending)
    Detail '这会让 msiexec 报 1618/1603。建议：先让它跑完 —— 若真失败，重启 VM 后重跑本脚本（journal 会续上，不会重复做）'
  } else {
    $pfro = Get-PfroCount
    if ($pfro -gt 0) {
      Detail ("PFRO 队列 {0} 条（PendingFileRenameOperations）：下次启动才执行，属正常现象，不影响安装 —— 无需处理" -f $pfro)
    }
  }
  $capState = 'unknown'
  try { $c = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop | Select-Object -First 1; if ($c) { $capState = [string]$c.State } } catch {}
  Detail ("OpenSSH.Server 能力当前状态：{0}" -f $capState)

  # 能力已装好，只需注册服务
  if ($capState -eq 'Installed') {
    Ok 'OpenSSH Server 可选功能已是安装状态，尝试注册服务'
    if (Start-InstallSshdScript) { $script:InstallUsed = 'capability'; return }
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { $script:InstallUsed = 'capability'; return }
    Warn '功能已标记安装但服务缺失，改用其它方式重装'
  }

  $order = @()
  # 若用户给了自定义源且没显式指定安装方式，就按扩展名推断（.msi/.zip）
  if ($DownloadUrl -and -not $script:MethodExplicit) {
    if ($DownloadUrl -match '(?i)\.zip(\?|$)') { $InstallMethod = 'Zip' }
    elseif ($DownloadUrl -match '(?i)\.msi(\?|$)') { $InstallMethod = 'Msi' }
    Detail ("按 -DownloadUrl 推断安装方式：{0}" -f $InstallMethod)
  }
  switch ($InstallMethod) {
    'Auto'       { $order = @('Msi', 'Zip', 'Winget') }   # 故意不含 Capability：它走 WU，国内基本必卡
    'Msi'        { $order = @('Msi') }
    'Zip'        { $order = @('Zip') }
    'Winget'     { $order = @('Winget') }
    'Dism'       { $order = @('Dism') }
    'Capability' { $order = @('Capability') }
  }
  Info ("安装方式顺序：{0}" -f ($order -join ' -> '))

  $i = 0
  foreach ($m in $order) {
    $i++
    Info ("方式{0}/{1}：{2}" -f $i, $order.Count, $m)
    try {
      switch ($m) {
        'Msi'    { Install-ViaMsi -LocalMsi $MsiPath; if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { return } }
        'Zip'    { Install-ViaZip -ZipPath $OpenSSHZipPath; if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { return } }
        'Winget' { if (Install-ViaWinget) { return } }
        'Dism' {
          # dism /online /add-capability 与 Add-WindowsCapability 同源（都取 Windows Update 源），
          # 国内通常一样慢；保留它是给"PowerShell 模块不可用但 dism.exe 可用"的环境兜底。
          Detail 'DISM 与 Add-WindowsCapability 同源（都走 Windows Update），国内可能同样慢；请耐心等待'
          Detail '若想快：用 -InstallMethod Msi，或 -DownloadUrl 指定一个你实测快的 msi/zip 直链'
          $dismLog = Join-Path $env:TEMP ('wb-dism-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
          $dismArgs = @('/online', '/add-capability', '/capabilityname:OpenSSH.Server~~~~0.0.1.0', '/quiet', '/norestart', "/logpath:$dismLog")
          Info ("执行：dism.exe {0}" -f ($dismArgs -join ' '))
          $outD = & dism.exe @dismArgs 2>&1 | Out-String
          $code = $LASTEXITCODE
          Detail ("dism 退出码：{0}（日志 {1}）" -f $code, $dismLog)
          if ($code -ne 0 -and $code -ne 3010) { throw ("dism 失败，退出码 {0}（3010=成功但需重启）。日志：{1}" -f $code, $dismLog) }
          if ($code -eq 3010) { Warn 'dism 返回 3010：安装成功但需重启才完全生效；本脚本会继续尝试启动服务' }
          if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { $script:InstallUsed = 'capability'; Ok '已通过 DISM 安装'; return }
          throw 'dism 完成但服务未出现（可能需重启 VM）'
        }
        'Capability' {
          $cap = $null
          try { $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop | Select-Object -First 1 } catch {}
          if (-not $cap) { throw '查询不到 OpenSSH.Server 能力（可能被策略屏蔽或 WU 不可用）' }
          Detail '走 Windows Update，可能要 1-5 分钟甚至更久；界面长时间不动属正常（这就是国内最慢的一步）'
          Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
          if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { $script:InstallUsed = 'capability'; Ok '已通过可选功能安装'; return }
          throw 'Add-WindowsCapability 完成但服务未出现'
        }
      }
      if (Get-Service -Name sshd -ErrorAction SilentlyContinue) { return }
      Warn ("方式 {0} 结束但 sshd 服务仍不存在，继续下一个方式" -f $m)
    } catch {
      Warn ("方式 {0} 失败：{1}" -f $m, ($_.Exception.Message -split "`n")[0])
    }
  }
  throw ("所有安装方式均失败（已尝试：{0}）。可手动下载 msi 后用 -MsiPath 指定，或重启 VM 清掉挂起操作后重跑" -f ($order -join ', '))
}

# =====================================================================
#  配置层
# =====================================================================
function Set-SshdDirectiveList {
  # 同 Set-SshdDirective，但支持**一个键多行值**（ListenAddress 允许多条）。
  # 策略：保留第一条原位置写入全部值，其余同键行注释掉（可回溯）。
  param(
    [System.Collections.Generic.List[string]]$Lines,
    [string]$Key,
    [string[]]$Values
  )
  $rx = '^\s*#?\s*' + [regex]::Escape($Key) + '(?:\s+|$)'
  $end = $Lines.Count
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match '^\s*Match\s') { $end = $i; break }
  }
  $first = -1
  for ($i = 0; $i -lt $end; $i++) {
    if ($Lines[$i] -match $rx) {
      if ($first -lt 0) { $first = $i } else { $Lines[$i] = '# [wb-dedup] ' + $Lines[$i].Trim() }
    }
  }
  $newLines = @($Values | ForEach-Object { "$Key $_" })
  if ($first -ge 0) {
    $Lines[$first] = $newLines[0]
    for ($k = 1; $k -lt $newLines.Count; $k++) { $Lines.Insert($first + $k, $newLines[$k]) }
  } else {
    $ins = $end
    while ($ins -gt 0 -and $Lines[$ins - 1].Trim() -eq '') { $ins-- }
    for ($k = 0; $k -lt $newLines.Count; $k++) { $Lines.Insert($ins + $k, $newLines[$k]) }
  }
}

function Resolve-ListenAddress {
  # 目标：只监听"宿主机可达的那块网卡"，不把 sshd 暴露到公网/Tailscale。
  # 优先：与 -AllowFrom 同 /24 的 IPv4；否则：默认路由所在网卡的 IPv4（排除 169.254 与 Tailscale）。
  param([string]$Hint)
  if (-not $Hint) { $Hint = 'auto' }
  $want = $Hint.Trim()
  if ($want -ieq 'all') { return '' }
  if ($want -ine 'auto') { return $want }

  $hintIp = ''
  if ($AllowFrom) { $hintIp = (($AllowFrom -split ',')[0]).Trim() }
  if ($hintIp -match '^(\d+)\.(\d+)\.(\d+)\.') {
    $pref = "$($Matches[1]).$($Matches[2]).$($Matches[3])."
    $c = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -like "$pref*" -and $_.IPAddress -ne $hintIp } |
         Select-Object -First 1
    if ($c) { return [string]$c.IPAddress }
  }
  $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
       Sort-Object RouteMetric | Select-Object -First 1
  if ($r) {
    $c = Get-NetIPAddress -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if ($c) { return [string]$c.IPAddress }
  }
  return ''
}

function Set-SshdDirective {
  param(
    [System.Collections.Generic.List[string]]$Lines,
    [string]$Key,
    [string]$Value
  )
  $rx = '^\s*#?\s*' + [regex]::Escape($Key) + '(?:\s+|$)'
  # 全局区终点：第一个 Match 块之后只能写子块指令
  $end = $Lines.Count
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match '^\s*Match\s') { $end = $i; break }
  }
  $first = -1
  for ($i = 0; $i -lt $end; $i++) {
    if ($Lines[$i] -match $rx) {
      if ($first -lt 0) { $first = $i }
      else { $Lines[$i] = '# [wb-dedup] ' + $Lines[$i].Trim() }
    }
  }
  if ($first -ge 0) { $Lines[$first] = "$Key $Value" }
  else {
    $ins = $end
    while ($ins -gt 0 -and $Lines[$ins - 1].Trim() -eq '') { $ins-- }
    $Lines.Insert($ins, "$Key $Value")
  }
}

function Add-KeyToFile {
  param([string]$Path, [string]$Key, [string]$KeyBlob)
  $dir = Split-Path -Parent $Path
  $dirExisted = Test-Path $dir
  if (-not $dirExisted) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $fileExisted = Test-Path $Path
  $aclBefore = ''
  if ($fileExisted) { $aclBefore = Get-AclSddl $Path }
  if (-not $fileExisted) { New-Item -ItemType File -Path $Path -Force | Out-Null }
  $existing = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
  $lineExisted = [bool](@($existing | Where-Object { $_ -and $_.Contains($KeyBlob) }).Count -gt 0)
  if (-not $lineExisted) { Add-Content -Path $Path -Value $Key -Encoding Ascii }

  $undo = [ordered]@{
    type        = 'remove_key_line'
    path        = $Path
    blob        = $KeyBlob
    fileExisted = $fileExisted
    dirExisted  = $dirExisted
    acl         = $aclBefore
  }
  $before = [ordered]@{ file = $Path; fileExisted = $fileExisted; dirExisted = $dirExisted; lineExisted = $lineExisted; acl = $aclBefore }
  $after  = [ordered]@{ file = $Path; lineAdded = (-not $lineExisted); lines = (@(Get-Content -Path $Path -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }).Count) }
  Add-Op 'authorized-keys' $before $undo $after 'ok' $Path

  if ($lineExisted) { Ok ("公钥已存在（未重复写入）-> {0}" -f $Path) }
  else { Ok ("已写入公钥 -> {0}" -f $Path); $script:ConfigChanged = $true }
  return $aclBefore
}

# =====================================================================
#  main
# =====================================================================
try {
  # ---------- 0) 权限与环境（软判定：-Continue 在非管理员下也能跑） ----------
  try {
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { $script:IsAdmin = $false }

  try { $script:SelfPath = [string]$MyInvocation.MyCommand.Path } catch { $script:SelfPath = '' }
  # irm|iex 时 MyCommand.Path 为空，但脚本已自落盘 ⇒ 用落盘副本做身份（sha256 才能对上）
  if (-not $script:SelfPath -and $script:SelfStaged -and (Test-Path -LiteralPath $script:SelfPathFinal)) { $script:SelfPath = $script:SelfPathFinal }
  if (-not $script:SelfPath) { $script:SelfPath = 'interactive-paste（整段粘贴执行）' }
  if ($script:SelfPath -and (Test-Path -LiteralPath $script:SelfPath)) { $script:SelfSha = Get-FileShaSafe $script:SelfPath }

  $pubUnset = [string]::IsNullOrWhiteSpace($PublicKey) -or ($PublicKey.Trim() -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)')

  # 模式判定：diag / rollback / build（日志文件名据此区分）
  $logMode = 'build'
  if ($diagMode) { $logMode = 'diag' }
  elseif ($rollbackMode) { $logMode = 'rollback' }
  Initialize-Log -Mode $logMode -Title ("user={0} port={1} dryRun={2}" -f $User, $Port, $dryRunMode)

  Say ''
  Say '================================================================' 'Cyan'
  $modeLabel = '构建通道（build）'
  if ($diagMode) { $modeLabel = '体检（-Continue，只读）' }
  elseif ($rollbackMode) { $modeLabel = '回滚（-Rollback）' }
  elseif ($dryRunMode) { $modeLabel = '预演（-DryRun，零副作用）' }
  Say (" wb-tunnel v{0}   {1}" -f $SCRIPT_VERSION, $modeLabel) 'Cyan'
  Say (" 目标：{0}@{1}:{2}     管理员：{3}     日志：{4}" -f $User, $env:COMPUTERNAME, $Port, $script:IsAdmin, $script:LogFile) 'Cyan'
  $stageNote = 'selfstage=' + $script:SelfStageMode
  if ($script:SelfUrlUsed) { $stageNote = $stageNote + '  <- ' + $script:SelfUrlUsed }
  Say (" 自落盘：{0}" -f $stageNote) 'Cyan'
  Say '================================================================' 'Cyan'

  # ---------- 1) -Rollback（可先回滚，再体检） ----------
  if ($rollbackMode) {
    if (-not $script:IsAdmin) { throw '回滚需要【管理员】PowerShell（右键“以管理员身份运行”）。' }
    Invoke-Rollback
    if (-not $diagMode) { return }
    Initialize-Log -Mode 'diag' -Title '回滚后体检'
    Warn '回滚已执行，继续做一次只读体检确认环境状态 ...'
    Show-Diagnostics
    return
  }

  # ---------- 2) -Continue ----------
  if ($diagMode) {
    Show-Diagnostics
    return
  }

  # ---------- 3) build 前置 ----------
  if (-not $script:IsAdmin) { throw '构建通道需要【管理员】PowerShell（右键“以管理员身份运行”）。' }
  Ok '管理员权限检查通过'

  if ($pubUnset -and ($dryRunMode -or $rollbackMode)) {
    # 回滚不需要公钥：remove_key_line 的 blob 已在 journal 里逐条记录
    if ($rollbackMode) { Detail '回滚模式：无需公钥（使用 journal 中记录的 blob）' }
    else { Warn 'DryRun：公钥未填入，跳过公钥校验（正式 build 会报错）' }
  } elseif ($pubUnset) {
    throw 'PublicKey 未提供或格式不对。请把宿主机 ~/.ssh/id_ed25519_winvm.pub 的内容填入 $PublicKey。'
  } else {
    $PublicKey = $PublicKey.Trim()
    Ok ("公钥已校验：{0}..." -f $PublicKey.Substring(0, [Math]::Min(32, $PublicKey.Length)))
  }

  $blob = ''
  $keyComment = ''
  if (-not $pubUnset) {
    $parts = $PublicKey -split '\s+'
    $blob = $parts[1]
    if ($parts.Count -ge 3) { $keyComment = $parts[2] }
  }

  # ---------- Stage 1：基线 ----------
  Enter-Stage '前置检查与基线采集'
  Step '采集构建前状态（写入 journal 的 baseline，destroy 用它兜底核对）'
  $script:Baseline = Get-BaselineSnapshot
  Ok ("sshd 变更前是否存在：{0}（StartType={1}）" -f $script:Baseline.sshdServiceExisted, $script:Baseline.sshdServiceStartType)
  Ok ("sshd_config 变更前是否存在：{0}    原始留档：{1}" -f $script:Baseline.configExisted, $script:Baseline.origStashExisted)
  Ok ("OpenSSH.Server 能力状态：{0}" -f $script:Baseline.capability)
  Detail ("网络配置档：{0}" -f (($script:Baseline.netProfiles | ForEach-Object { $_.alias + '=' + $_.category }) -join ' / '))
  Detail ("防火墙基线：{0}" -f (($script:Baseline.firewall | ForEach-Object { $_.name + '=' + $(if ($_.existed) { 'exists' } else { 'absent' }) }) -join ' / '))
  Detail ("账户：{0} exists={1} enabled={2} passwordRequired={3}" -f $script:Baseline.account.name, $script:Baseline.account.exists, $script:Baseline.account.enabled, $script:Baseline.account.passwordRequired)

  # 历史遗留识别：用户 profile 的 authorized_keys 若"构建前就含本通道公钥"，
  # 说明这条通道是别人/旧版本留下的。因 Match Group administrators 生效，该位置不参与认证，
  # 但必须说清"destroy 不会动它"（它属于构建前状态，不是本次操作的产物）。
  $profAk = @($script:Baseline.authFiles | Where-Object { $_.path -and $_.path -notmatch 'ProgramData' })
  foreach ($a in $profAk) {
    if ($a.existed -and $a.hasTunnelKey) {
      Warn ("用户 profile 授权文件构建前就已含本通道公钥：{0}" -f $a.path)
      Warn '  当前配置下 Match Group administrators 生效，该位置不参与认证（死配置）'
      Warn '  destroy 不会删除它 —— 它属于"构建前状态"，不是本次操作的产物'
    } elseif (-not $a.existed) {
      Detail ("用户 profile 授权文件：不存在（{0}）" -f $a.path)
    }
  }

  $script:state = New-Journal
  if ($script:state.params) {
    $script:state.params.publicKeyBlob = $blob
    $script:state.params.publicKeySha256 = (Get-Sha256Text $PublicKey)
    $script:state.params.publicKeyComment = $keyComment
    if (-not $dryRunMode) { Save-WbState $script:state }
  }
  Detail ("公钥指纹(sha256) ：{0}" -f $script:state.params.publicKeySha256)
  Detail ("公钥注释         ：{0}" -f $keyComment)
  Exit-Stage

  # ---------- Stage 2：安装 ----------
  Enter-Stage '安装 OpenSSH Server（默认 MSI 静默安装，不用 ISO）'
  $preService = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if ($dryRunMode) {
    Warn 'DryRun：跳过安装（不下载、不安装服务、不改系统）'
    Detail ("正式执行时将采用：-InstallMethod {0}" -f $InstallMethod)
    if ($MsiPath) { Detail ("本地 msi：{0}" -f $MsiPath) }
    if ($OpenSSHZipPath) { Detail ("本地 zip：{0}" -f $OpenSSHZipPath) }
  } else {
    Ensure-OpenSSHServer
  }
  if ($preService) {
    # 只做审计，不带 undo；用独立 action 名，避免和"本轮真装了"的条目互相覆盖
    Add-Op 'install-sshd-skipped' @{ serviceExisted = $true; startType = [string]$preService.StartType } $null @{ serviceExisted = $true }
    Ok 'sshd 变更前已存在 -> 不记录卸载动作（destroy 保留服务，只撤配置/公钥/防火墙/网络）'
  } elseif ($dryRunMode) {
    Ok 'DryRun：跳过安装，不记录 journal'
  } else {
    $m = $script:InstallUsed
    if (-not $m) { $m = 'capability' }
    if ($m -eq 'capability') {
      $undoIns = [ordered]@{ type = 'remove_capability'; name = 'OpenSSH.Server~~~~0.0.1.0' }
    } else {
      $undoIns = [ordered]@{
        type   = 'uninstall_openssh'
        script = 'C:\Program Files\OpenSSH\uninstall-sshd.ps1'
        dir    = 'C:\Program Files\OpenSSH'
      }
      if ($m -eq 'winget') { $undoIns['winget'] = 'Microsoft.OpenSSH.Preview' }
      if ($m -eq 'msi' -and $script:MsiProductCode) { $undoIns['msi'] = $script:MsiProductCode }
    }
    $svcNow = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $stNow = 'absent'
    if ($svcNow) { $stNow = [string]$svcNow.Status }
    $afterIns = @{ method = $m; serviceStatus = $stNow }
    if ($m -eq 'msi') {
      $afterIns['msiFile']      = [string]$script:MsiUsed
      $afterIns['msiUrl']       = [string]$script:MsiSourceUrl
      $afterIns['msiProduct']   = [string]$script:MsiProductCode
      $afterIns['msiLog']       = [string]$script:MsiLogFile
    }
    Add-Op 'install-sshd' @{ serviceExisted = $false; capability = $script:Baseline.capability } $undoIns $afterIns 'ok' 'sshd'
    Ok ("本次安装方式：{0}（destroy 将据此卸载）" -f $m)
  }
  Exit-Stage

  # ---------- Stage 3：启动 + 自启 ----------
  Enter-Stage '启动 sshd 并设为自启'
  if ($dryRunMode) {
    Warn 'DryRun：跳过服务启动'
  } else {
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $svc) { throw '未检测到 sshd 服务，安装未完成' }
    $origStart = [string]$svc.StartType
    $origStatus = [string]$svc.Status
    Detail ("变更前：Status={0}  StartType={1}" -f $origStatus, $origStart)
    $svcChanged = $false
    if ($origStart -ne 'Automatic') {
      Set-Service -Name sshd -StartupType Automatic
      Detail 'StartType -> Automatic'
      $svcChanged = $true
    }
    if ((Get-Service -Name sshd).Status -ne 'Running') {
      Step 'Start-Service sshd ...'
      Start-Service -Name sshd
      Start-Sleep -Seconds 1
      $svcChanged = $true
    }
    $svc2 = Get-Service -Name sshd
    Ok ("当前：Status={0}  StartType={1}" -f $svc2.Status, $svc2.StartType)
    if ($svcChanged) {
      Add-Op 'service-autostart' @{ startType = $origStart; status = $origStatus } ([ordered]@{ type = 'restore_service_starttype'; value = $origStart }) @{ startType = [string]$svc2.StartType; status = [string]$svc2.Status } 'ok' 'sshd'
    } else {
      Ok '已是 Automatic 且 Running -> 本次无变更，不记 journal（幂等）'
    }
  }
  $sshdExe = Get-SshdExe
  if ($sshdExe -and (Test-Path $sshdExe)) { Ok ("sshd.exe = {0}" -f $sshdExe) }
  elseif ($dryRunMode) { Warn 'DryRun：未找到 sshd.exe，跳过语法校验（仅预览生成逻辑）' }
  else { throw '找不到 sshd.exe，安装可能不完整' }
  Exit-Stage

  # ---------- Stage 4：配置 ----------
  Enter-Stage '配置 sshd_config（含安全基线）'
  $cfgSrc = $SSHD_CFG
  if (-not (Test-Path $cfgSrc)) {
    if ($dryRunMode) {
      Warn 'DryRun：sshd_config 不存在（尚未安装），用内置样例预演"配置生成"逻辑'
      $cfgSrc = Join-Path $env:TEMP 'wb-dryrun-base.conf'
      @('Port 22',
        'PubkeyAuthentication yes',
        'PasswordAuthentication yes',
        'Match Group administrators',
        '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys') |
        Set-Content -Path $cfgSrc -Encoding Ascii
    } else {
      # 个别安装方式（MSI/精简）不带默认 sshd_config -> 用最小安全基线从零生成，而不是直接失败
      Warn ("{0} 不存在 -> 按最小安全基线从零生成（记录为「新建文件」，destroy 时整文件删除）" -f $SSHD_CFG)
      $cfgSrc = Join-Path $env:TEMP 'wb-base-min.conf'
      @('Port 22',
        'PubkeyAuthentication yes',
        'PasswordAuthentication yes',
        'Match Group administrators',
        '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys') |
        Set-Content -Path $cfgSrc -Encoding Ascii
    }
  }

  # 原始配置留档（固定名 .wb-orig：重复执行不会被覆盖，确保回滚总回到"最初"）
  if (Test-Path $SSHD_CFG) {
    if (-not (Test-Path $OrigBak)) {
      if ($dryRunMode) {
        Ok ("DryRun：将留档原始配置 -> {0}" -f $OrigBak)
      } else {
        Copy-Item -Path $SSHD_CFG -Destination $OrigBak -Force
        Add-Op 'stash-original-config' @{ path = $SSHD_CFG; stash = $OrigBak } ([ordered]@{ type = 'delete_file'; path = $OrigBak }) @{ stashSha = (Get-FileShaSafe $OrigBak) } 'ok' 'sshd_config'
        Ok ("原始 sshd_config 已留档 -> {0}（destroy 会先还原再删除留档）" -f $OrigBak)
      }
    } else {
      Ok ("原始配置留档已存在（保留首次的）-> {0}" -f $OrigBak)
    }
  }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($l in (Get-Content -Path $cfgSrc)) { $lines.Add($l) }

  Set-SshdDirective $lines 'Port'                 "$Port"
  Set-SshdDirective $lines 'PubkeyAuthentication' 'yes'

  # ---- 监听范围：只绑内网网卡 + 回环，避免把 sshd 暴露到公网 / Tailscale ----
  $resolvedListen = Resolve-ListenAddress $ListenAddress
  if ($resolvedListen) {
    Set-SshdDirectiveList $lines 'ListenAddress' @($resolvedListen, '127.0.0.1')
    Ok ("仅监听：{0} + 127.0.0.1（不写 0.0.0.0，公网/Tailscale 无法直连）" -f $resolvedListen)
    if ($AllowFrom) { Detail ("防火墙将只放行来源：{0}" -f $AllowFrom) }
    else { Warn '未给 -AllowFrom：监听虽已收窄，但同网段其它主机仍可连；建议配 -AllowFrom <宿主机IP>' }
  } elseif ($ListenAddress -and $ListenAddress -ine 'all') {
    Warn ("无法解析 -ListenAddress={0} -> 保持监听全部地址；请显式传 -ListenAddress <VM内网IP>" -f $ListenAddress)
  } else {
    Detail '未限制 ListenAddress（监听全部地址）——如需"仅宿主机可连"，用 -ListenAddress auto'
  }

  # ---- 密码认证：默认保留（用户要求"密码登录仍被允许"），仅 -Harden 才关闭 ----
  if ($doHarden) {
    Set-SshdDirective $lines 'PasswordAuthentication' 'no'
    Set-SshdDirective $lines 'MaxAuthTries'           '3'
    Set-SshdDirective $lines 'LoginGraceTime'         '30'
    Warn '已按 -Harden 关闭密码认证（PasswordAuthentication no）'
  } else {
    Set-SshdDirective $lines 'PasswordAuthentication' 'yes'
    Detail 'PasswordAuthentication yes —— 保留密码登录（要关闭请显式加 -Harden）'
  }

  # ---- 空密码：默认禁止（安全底线）。auto 只探测、不放开 ----
  #     放开 PermitEmptyPasswords 会让 none 认证直接通过 = 匿名登录，公钥失效。
  $emptyMode = [string]$EmptyPasswordMode
  if ($doHarden) { $emptyMode = 'no' }
  elseif ($AllowEmptyPassword) { $emptyMode = 'yes' }
  if ($emptyMode -eq 'auto') {
    $blank = Test-AccountHasBlankPassword $User
    $emptyMode = 'no'   # 无论探测结果如何，都不放开 —— 见头部说明
    if ($blank -eq $true) {
      Detail ("探测：账户 {0} 确认为空密码 -> PermitEmptyPasswords 保持 no（安全）" -f $User)
      Detail '        空密码账户改走公钥认证（公钥不核对密码，这是本 skill 的正确路径）'
    } elseif ($blank -eq $false) {
      Detail ("探测：账户 {0} 已设密码 -> PermitEmptyPasswords 保持 no（Windows 默认基线）" -f $User)
    } else {
      Detail ("探测：无法判定账户 {0} 的密码状态 -> PermitEmptyPasswords 保持 no（安全默认）" -f $User)
    }
  }
  $script:EmptyUsed = $emptyMode

  if ($emptyMode -eq 'yes') {
    Warn '============================================================'
    Warn ' 危险：-EmptyPasswordMode yes 会写 PermitEmptyPasswords yes'
    Warn ' OpenSSH 的 none 认证随后会直接通过 => 任何人无需任何凭据'
    Warn ' 即可登录（Accepted none），公钥通道形同虚设。'
    Warn ' 仅在"确实需要空密码走密码通道"时使用，且必须靠 -AllowFrom'
    Warn ' + ListenAddress 把可达面压到最小。'
    Warn '============================================================'
    Set-SshdDirective $lines 'PermitEmptyPasswords' 'yes'
    # 只放开 sshd 还不够：LimitBlankPasswordUse=1 会在 LSA 层直接拒绝"空密码网络登录"，
    # 表现为客户端 Password: 敲回车 -> Permission denied，且 sshd 日志看不出原因。
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $cur = Get-LsaBlankPasswordPolicy
    if ($cur -eq 0) {
      Detail 'LimitBlankPasswordUse 已是 0（允许空密码网络登录），无需改动'
    } else {
      New-ItemProperty -Path $lsa -Name 'LimitBlankPasswordUse' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
      Add-Op 'allow-blank-network-logon' @{ path = $lsa; name = 'LimitBlankPasswordUse'; value = $cur } ([ordered]@{
          type  = 'restore_registry_value'; path = $lsa; name = 'LimitBlankPasswordUse'
          value = $cur; kind = 'DWord'
        }) @{ value = 0 } 'ok' 'LimitBlankPasswordUse'
      if ($null -eq $cur) {
        Warn 'LimitBlankPasswordUse 原本不存在，已设为 0（destroy 会删掉这个值，恢复"不存在"）'
      } else {
        Warn ("LimitBlankPasswordUse {0} -> 0，允许空密码网络登录（destroy 会还原为 {0}）" -f $cur)
      }
    }
  } else {
    Set-SshdDirective $lines 'PermitEmptyPasswords' 'no'
    # 配置自洽：历史上"放开空密码"的构建会顺手把 LimitBlankPasswordUse 改成 0。
    # 现在不放开空密码了，那层放宽必须一起收回 —— 否则少挡一层，哪天有人把
    # PermitEmptyPasswords 改回 yes 就直接退化成 none 匿名登录。
    # 只撤本账本自己改的那次（有 before 记录），别处设的 0 一律不碰。
    $lbpNow = Get-LsaBlankPasswordPolicy
    if ($lbpNow -eq 0) {
      Warn 'LimitBlankPasswordUse 当前 = 0（空密码网络登录在 LSA 层被允许）-> 尝试收回，恢复配置自洽'
      Restore-WidenedBlankLogon
    }
  }
  if (-not (($lines -join "`n") -match '(?im)^\s*Match\s+Group\s+administrators')) {
    $lines.Add('')
    $lines.Add('Match Group administrators')
    $lines.Add('       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys')
    Ok '已补回 Match Group administrators 块（管理员公钥重定向）'
  }

  $preview = Join-Path $env:TEMP 'sshd_config.preview'
  Set-Content -Path $preview -Value $lines -Encoding Ascii

  if ($sshdExe) {
    Step 'sshd -t 语法校验（先校验预览副本，零风险）...'
    $out = & $sshdExe -t -f $preview 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
      throw ("配置语法校验失败（exit={0}）：{1}  预览：{2}" -f $LASTEXITCODE, ($out.Trim() -replace "`r?`n", ' | '), $preview)
    }
    Ok '语法校验通过'
  } else {
    Warn 'DryRun：无 sshd.exe，跳过语法校验（仅展示将写入的配置）'
  }

  Say ''
  Info '生效配置关键行：'
  Select-String -Path $preview -Pattern '^\s*(Port|ListenAddress|PubkeyAuthentication|PasswordAuthentication|PermitEmptyPasswords|MaxAuthTries|LoginGraceTime|Match|AuthorizedKeysFile)\b' |
    ForEach-Object { Detail $_.Line.Trim() }
  Say ''

  if ($dryRunMode) {
    Ok ("DryRun 完成（未写入 / 未重启 / 未写公钥）。预览文件：{0}" -f $preview)
    Detail 'DryRun 覆盖范围：配置生成 + 语法校验；不含网络档/防火墙/ACL/服务重启'
    Detail '要确认"外部能不能连上"，用 -Continue 看服务/监听/网络档/防火墙/公钥四项'
    Exit-Stage '（DryRun 到此结束）'
    Say ''
    Warn 'DryRun 结束：系统未被改动。去掉 -DryRun 再执行即为真实构建。'
    return
  }

  # 真实应用：先判"内容是否已一致"（幂等闸门）-> 备份 -> 写入 -> 再校验 -> 失败自动还原
  $cfgShaBefore = Get-FileShaSafe $SSHD_CFG
  $cfgShaWanted = Get-FileShaSafe $preview
  $cfgUnchanged = [bool]((Test-Path $SSHD_CFG) -and $cfgShaWanted -and ($cfgShaBefore -eq $cfgShaWanted))

  if ($cfgUnchanged) {
    Ok 'sshd_config 已是目标内容（sha256 一致）-> 跳过备份/写入/记 journal（幂等，不产生重复条目）'
    Exit-Stage
  }

  $bak = ''
  if (Test-Path $SSHD_CFG) {
    $bak = "$SSHD_CFG.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -Path $SSHD_CFG -Destination $bak -Force
    Add-Op 'backup-config' @{ path = $SSHD_CFG; sha256 = $cfgShaBefore } ([ordered]@{ type = 'delete_file'; path = $bak }) @{ path = $bak } 'ok' $bak
    Ok ("已备份：{0}" -f $bak)
  } else {
    Warn 'sshd_config 原本不存在 -> 本次属"新建"，destroy 时整文件删除（不删配置目录，除非本来就是空的）'
  }

  $undoCfg = [ordered]@{ type = 'delete_file'; path = $SSHD_CFG }
  if (Test-Path $OrigBak) { $undoCfg = [ordered]@{ type = 'restore_file'; path = $SSHD_CFG; from = $OrigBak } }
  Add-Op 'write-sshd-config' @{ path = $SSHD_CFG; port = $Port; harden = $doHarden; sha256Before = $cfgShaBefore; existedBefore = (Test-Path $SSHD_CFG) } $undoCfg @{ sha256After = '' } 'ok' 'sshd_config'
  if (-not (Test-Path (Split-Path -Parent $SSHD_CFG))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SSHD_CFG) | Out-Null }
  Set-Content -Path $SSHD_CFG -Value $lines -Encoding Ascii
  $out2 = & $sshdExe -t 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    if ($bak -and (Test-Path $bak)) { Copy-Item -Path $bak -Destination $SSHD_CFG -Force }
    throw ("真实配置校验失败，已自动回滚到 {0}（服务未重启，通道未受影响）：{1}" -f $bak, ($out2.Trim() -replace "`r?`n", ' | '))
  }
  # 记录写入后的实际哈希（便于 destroy 前后核对）
  Set-LastOpAfter 'sha256After' (Get-FileShaSafe $SSHD_CFG)
  if (-not $dryRunMode) { Save-WbState $script:state }
  Ok '真实配置校验通过（重启放到最后统一执行）'
  $script:ConfigChanged = $true
  Exit-Stage

  # ---------- Stage 5：公钥 + ACL ----------
  Enter-Stage '部署公钥并收紧 ACL'
  $isTargetAdmin = $false
  try {
    $grp = $null
    try { $grp = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop } catch { $grp = Get-LocalGroup -Group 'Administrators' -ErrorAction Stop }
    $members = @(Get-LocalGroupMember -Group $grp.Name -ErrorAction Stop | ForEach-Object { $_.Name })
    $isTargetAdmin = @($members | Where-Object { $_ -eq $User -or $_ -match ('\\' + [regex]::Escape($User) + '$') }).Count -gt 0
    Ok ("目标用户 {0} / 管理员={1}" -f $User, $isTargetAdmin)
  } catch {
    Warn ("无法判定管理员组，默认按管理员处理：{0}" -f ($_.Exception.Message -split "`n")[0])
    $isTargetAdmin = $true
  }

  if ($isTargetAdmin) {
    $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
    Add-KeyToFile -Path $ak -Key $PublicKey -KeyBlob $blob | Out-Null
    Step 'icacls 收紧：仅 Administrators(S-1-5-32-544) + SYSTEM(S-1-5-18)'
    & icacls.exe $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' *>&1 | Out-Null
    $aclAfter = Get-AclSddl $ak
    Set-LastOpAfter 'aclAfter' $aclAfter
    if (-not $dryRunMode) { Save-WbState $script:state }
    Ok 'ACL 已收紧（destroy 用 journal 里的 SDDL 精确还原，或随文件一并移除）'
  } else {
    $home2  = Get-UserProfileDir $User
    $sshDir = Join-Path $home2 '.ssh'
    $ak     = Join-Path $sshDir 'authorized_keys'
    $dirAclBefore = ''
    if (Test-Path $sshDir) { $dirAclBefore = Get-AclSddl $sshDir }
    Add-KeyToFile -Path $ak -Key $PublicKey -KeyBlob $blob | Out-Null
    if ($dirAclBefore) { Set-LastOpUndo 'dirAcl' $dirAclBefore }
    Step 'icacls 收紧：.ssh 目录与 authorized_keys 仅目标用户 + SYSTEM'
    & icacls.exe $sshDir /inheritance:r /grant ("{0}:(OI)(CI)F" -f $User) /grant '*S-1-5-18:F' *>&1 | Out-Null
    & icacls.exe $ak     /inheritance:r /grant ("{0}:F" -f $User)         /grant '*S-1-5-18:F' *>&1 | Out-Null
    $aclAfter = Get-AclSddl $ak
    Set-LastOpAfter 'aclAfter' $aclAfter
    if (-not $dryRunMode) { Save-WbState $script:state }
    Ok 'ACL 已收紧（destroy 用 journal 里的 SDDL 精确还原，或随文件/目录一并移除）'
  }
  Exit-Stage

  # ---------- Stage 6：网络配置档 ----------
  Enter-Stage '网络配置档（Public 会挡掉端口）'
  try {
    foreach ($pf in @(Get-NetConnectionProfile -ErrorAction Stop)) {
      if ([string]$pf.NetworkCategory -eq 'Public') {
        Warn ("配置档为 Public：{0}（{1}）—— Domain/Private 专属规则不生效，22/3389/445 会被静默丢弃" -f $pf.Name, $pf.InterfaceAlias)
        try {
          Set-NetConnectionProfile -InterfaceAlias $pf.InterfaceAlias -NetworkCategory Private -ErrorAction Stop
          Add-Op 'net-profile-private' @{ alias = [string]$pf.InterfaceAlias; category = 'Public' } ([ordered]@{ type = 'restore_net_profile'; alias = [string]$pf.InterfaceAlias; category = 'Public' }) @{ category = 'Private' } 'ok' ([string]$pf.InterfaceAlias)
          Ok ("已改为 Private：{0}（destroy 会改回 Public）" -f $pf.InterfaceAlias)
          $script:ConfigChanged = $true
        } catch {
          Warn ("改 Private 失败（需在 VM 本机手动改）：{0}" -f ($_.Exception.Message -split "`n")[0])
        }
      } else {
        Ok ("配置档：{0} = {1}（无需改动）" -f $pf.InterfaceAlias, $pf.NetworkCategory)
      }
    }
  } catch {
    Warn ("无法读取网络配置档：{0}" -f ($_.Exception.Message -split "`n")[0])
  }
  Exit-Stage

  # ---------- Stage 7：防火墙 ----------
  Enter-Stage '防火墙放行（与 Port 强一致，覆盖所有配置档）'
  # 来源限制：给了 -AllowFrom 就只放行这些地址（+ 本机回环），否则保持 Any
  $remoteList = @()
  if ($AllowFrom) {
    $remoteList = @($AllowFrom -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($remoteList -notcontains '127.0.0.1') { $remoteList += '127.0.0.1' }
    Ok ("来源限制：只放行 {0}（回环含在内）" -f ($remoteList -join ', '))
  } else {
    Detail '未给 -AllowFrom -> 规则对任意来源放行（仍受 ListenAddress 收窄保护）'
  }
  $fwName = 'OpenSSH-Server-In-TCP'
  $fw = Get-NetFirewallRule -Name $fwName -ErrorAction SilentlyContinue
  if ($fw) {
    $origEnabled = [bool]$fw.Enabled
    $origProfile = [string]$fw.Profile
    $origPort = ''
    try { $origPort = [string]($fw | Get-NetFirewallPortFilter -ErrorAction Stop).LocalPort } catch {}
    $origRem = ''
    try { $origRem = (@(($fw | Get-NetFirewallAddressFilter -ErrorAction Stop).RemoteAddress) -join ',') } catch {}
    Detail ("变更前：Enabled={0} Profile={1} Port={2} Remote={3} Action={4}" -f $origEnabled, $origProfile, $origPort, $origRem, [string]$fw.Action)
    $remNow = (@($origRem -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) -join ',')
    $remWant = (@($remoteList | Sort-Object) -join ',')
    $remOk = $true
    if ($remoteList.Count -gt 0) { $remOk = ($remNow -eq $remWant) }
    if ($origEnabled -and ($origProfile -eq 'Any') -and ($origPort -eq [string]$Port) -and ([string]$fw.Action -eq 'Allow') -and $remOk) {
      Ok ("规则已是目标态（Enabled / Profile Any / Port {0} / Remote {1} / Allow）-> 跳过（幂等）" -f $Port, ($(if($remoteList.Count){$remWant}else{'Any'})))
    } else {
      $setArgs = @{ Name = $fwName; Enabled = 'True'; Profile = 'Any'; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; LocalPort = $Port }
      if ($remoteList.Count -gt 0) { $setArgs['RemoteAddress'] = $remoteList }
      Set-NetFirewallRule @setArgs | Out-Null
      Add-Op 'firewall-allow' @{ name = $fwName; existed = $true; enabled = $origEnabled; profile = $origProfile; port = $origPort; remoteAddress = $origRem } ([ordered]@{
          type = 'restore_firewall_rule'; name = $fwName; enabled = $origEnabled; profile = $origProfile; localPort = $origPort; remoteAddress = $origRem
        }) @{ enabled = $true; profile = 'Any'; port = $Port; remoteAddress = $(if($remoteList.Count){$remWant}else{'Any'}) } 'ok' $fwName
      Ok ("规则已更新：TCP {0} / Profile Any / Remote {1}（destroy 会还原 Enabled/Profile/Port/Remote）" -f $Port, $(if($remoteList.Count){$remWant}else{'Any'}))
      $script:ConfigChanged = $true
    }
  } else {
    $nArgs = @{ Name = $fwName; DisplayName = 'OpenSSH Server (sshd)'; Enabled = 'True'; Profile = 'Any'; Direction = 'Inbound'; Protocol = 'TCP'; Action = 'Allow'; LocalPort = $Port }
    if ($remoteList.Count -gt 0) { $nArgs['RemoteAddress'] = $remoteList }
    New-NetFirewallRule @nArgs | Out-Null
    Add-Op 'firewall-allow' @{ name = $fwName; existed = $false } ([ordered]@{ type = 'remove_firewall_rule'; name = $fwName }) @{ enabled = $true; profile = 'Any'; port = $Port; remoteAddress = $(if($remoteList.Count){$remWant}else{'Any'}) } 'ok' $fwName
    Ok ("已新建规则：TCP {0} / Remote {1}（destroy 会删除）" -f $Port, $(if($remoteList.Count){$remWant}else{'Any'}))
    $script:ConfigChanged = $true
  }

  # 兜底：独立规则，防系统预置规则被组策略重置
  $wbRule = 'OpenSSH-Server-In-TCP-WB'
  $fwWb = Get-NetFirewallRule -Name $wbRule -ErrorAction SilentlyContinue
  if (-not $fwWb) {
    $nArgs2 = @{ Name = $wbRule; DisplayName = 'OpenSSH Server (sshd) - WorkBuddy'; Enabled = 'True'; Profile = 'Any'; Direction = 'Inbound'; Protocol = 'TCP'; Action = 'Allow'; LocalPort = $Port }
    if ($remoteList.Count -gt 0) { $nArgs2['RemoteAddress'] = $remoteList }
    New-NetFirewallRule @nArgs2 | Out-Null
    Add-Op 'firewall-allow-fallback' @{ name = $wbRule; existed = $false } ([ordered]@{ type = 'remove_firewall_rule'; name = $wbRule }) @{ enabled = $true; profile = 'Any'; port = $Port; remoteAddress = $(if($remoteList.Count){$remWant}else{'Any'}) } 'ok' $wbRule
    Ok ("已追加兜底规则：{0}（同源限制，destroy 会删除）" -f $wbRule)
    $script:ConfigChanged = $true
  } else {
    $en2 = [bool]$fwWb.Enabled
    $pf2 = [string]$fwWb.Profile
    $port2 = ''
    try { $port2 = [string]($fwWb | Get-NetFirewallPortFilter -ErrorAction Stop).LocalPort } catch {}
    $rem2 = ''
    try { $rem2 = (@(($fwWb | Get-NetFirewallAddressFilter -ErrorAction Stop).RemoteAddress) -join ',') } catch {}
    Detail ("兜底规则变更前：Enabled={0} Profile={1} Port={2} Remote={3}" -f $en2, $pf2, $port2, $rem2)
    $rem2Now = (@($rem2 -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) -join ',')
    $rem2Ok = $true
    if ($remoteList.Count -gt 0) { $rem2Ok = ($rem2Now -eq $remWant) }
    if ($en2 -and ($pf2 -eq 'Any') -and ($port2 -eq [string]$Port) -and $rem2Ok) {
      Ok '兜底规则已是目标态 -> 跳过（幂等）'
    } else {
      $setArgs2 = @{ Name = $wbRule; Enabled = 'True'; Profile = 'Any'; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; LocalPort = $Port }
      if ($remoteList.Count -gt 0) { $setArgs2['RemoteAddress'] = $remoteList }
      Set-NetFirewallRule @setArgs2 | Out-Null
      Add-Op 'firewall-allow-fallback' @{ name = $wbRule; existed = $true; enabled = $en2; profile = $pf2; port = $port2; remoteAddress = $rem2 } ([ordered]@{
          type = 'restore_firewall_rule'; name = $wbRule; enabled = $en2; profile = $pf2; localPort = $port2; remoteAddress = $rem2
        }) @{ enabled = $true; profile = 'Any'; port = $Port; remoteAddress = $(if($remoteList.Count){$remWant}else{'Any'}) } 'ok' $wbRule
      Ok ("兜底规则已同步：{0}" -f $wbRule)
      $script:ConfigChanged = $true
    }
  }

  # 关键：Windows 防火墙对同端口的多条 Allow 规则是「或」关系——
  # 只要还有一条任意来源的放行规则，上面的 RemoteAddress 限制就等于没设。
  # 实现要点：**一次性**取全量 PortFilter 再在内存关联规则名。
  #   逐条 `$rule | Get-NetFirewallPortFilter` 是 O(N) 次 CIM 往返，实测 500+ 条规则要 386 秒；
  #   全量一次只要 ~1.8 秒。PortFilter.InstanceID 恰好就是规则名，可直接拿来做键。
  if ($remoteList.Count -gt 0) {
    try {
      $swDet = [System.Diagnostics.Stopwatch]::StartNew()
      Step ("扫描其它放行 TCP {0} 的规则（一次性取 PortFilter，约 2-6 秒）..." -f $Port)
      $nameSet = @{}
      foreach ($f in @(Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
        $lp = [string]$f.LocalPort
        if (-not $lp) { continue }
        $hitPort = $false
        foreach ($one in ($lp -split ',')) {
          if ($one.Trim() -eq [string]$Port) { $hitPort = $true; break }
        }
        if (-not $hitPort) { continue }
        $proto = [string]$f.Protocol
        if ($proto -and $proto -notin @('TCP', 'Any', '6')) { continue }
        $id = [string]$f.InstanceID
        if ($id) { $nameSet[$id] = $true }
      }
      Detail ("命中 {0} 条覆盖 TCP {1} 的过滤器（用时 {2:N1}s）" -f $nameSet.Count, $Port, $swDet.Elapsed.TotalSeconds)

      $bypass = @()
      foreach ($n in @($nameSet.Keys)) {
        if ($n -in @($fwName, $wbRule)) { continue }
        $r = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
        if (-not $r) { continue }
        if ([string]$r.Direction -ne 'Inbound') { continue }
        if ([string]$r.Action    -ne 'Allow')   { continue }
        if ([string]$r.Enabled   -ne 'True')    { continue }
        $ra = ''
        try { $ra = (@(($r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress) -join ',') } catch {}
        if ($ra -notmatch '(^|,)Any(,|$)') { continue }   # 已受限的不用管
        $bypass += [pscustomobject]@{ Name = [string]$r.Name; Display = [string]$r.DisplayName; Remote = $ra }
      }

      if ($bypass.Count -eq 0) {
        Ok ("无其它规则对任意来源放行 TCP {0}（来源限制有效）" -f $Port)
      } else {
        Warn ("发现 {0} 条规则仍对任意来源放行 TCP {1} —— 它们会让 -AllowFrom 失效：" -f $bypass.Count, $Port)
        foreach ($o in $bypass) { Detail ("  - {0}  [{1}]  Remote=Any" -f $o.Name, $o.Display) }
        Warn '现在把它们一并收窄到 -AllowFrom（每条都记 journal，destroy 会逐条还原）'
        $fixed = 0
        foreach ($o in $bypass) {
          try {
            $rr = Get-NetFirewallRule -Name $o.Name -ErrorAction Stop
            $beforeRa = [string]$o.Remote
            $rr | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $remoteList -ErrorAction Stop | Out-Null
            Add-Op 'firewall-narrow-existing' @{ name = $o.Name; display = $o.Display; remoteAddress = $beforeRa } ([ordered]@{
                type = 'restore_firewall_rule'; name = $o.Name; remoteAddress = $beforeRa
              }) @{ remoteAddress = ($remoteList -join ','); reason = 'bypass-detected' } 'ok' $o.Name
            Detail ("  [+] 已收窄：{0}  Remote {1} -> {2}" -f $o.Name, $beforeRa, ($remoteList -join ','))
            $fixed++
          } catch {
            Warn ("  [x] 收窄失败 {0}：{1}" -f $o.Name, ($_.Exception.Message -split "`n")[0])
          }
        }
        if ($fixed -gt 0) {
          Ok ("已收窄 {0}/{1} 条；如需保留某条原状，destroy 后单独调整" -f $fixed, $bypass.Count)
          $script:ConfigChanged = $true
        }
      }
    } catch {
      Warn ("旁路规则扫描失败：{0}" -f ($_.Exception.Message -split "`n")[0])
      Detail '这不影响通道本身，但"仅宿主机可连"可能不成立；可稍后用 -Continue 复查'
    }
  } else {
    Detail '未限定 -AllowFrom，跳过旁路规则扫描（当前对任意来源放行）'
  }
  Exit-Stage

  # ---------- Stage 8：自检 ----------
  Enter-Stage '自检（重启前）'
  $svc = Get-Service -Name sshd
  Detail ("服务        ：{0} / {1}" -f $svc.Status, $svc.StartType)
  Detail ("端口        ：TCP {0}" -f $Port)
  if ($doHarden) {
    Detail '安全基线    ：已按 -Harden 收紧（密码认证关闭）'
  } else {
    $emptyTxt = $script:EmptyUsed
    if ($emptyTxt -eq 'yes') { $emptyTxt = 'yes（⚠ 已放开 => none 匿名登录开启，公钥形同虚设）' }
    elseif ($emptyTxt -eq 'no') { $emptyTxt = 'no（禁止；空密码账户只能走公钥）' }
    Detail ("安全基线    ：保留密码登录（PasswordAuthentication yes）；空密码={0}" -f $emptyTxt)
  }
  foreach ($f in @('C:\ProgramData\ssh\administrators_authorized_keys', (Join-Path (Join-Path (Get-UserProfileDir $User) '.ssh') 'authorized_keys'))) {
    if (Test-Path $f) {
      $lnCnt = @(Get-Content -Path $f -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }).Count
      Detail ("授权文件    ：{0}  （{1} 行）" -f $f, $lnCnt)
    }
  }
  Detail ("配置备份    ：{0}" -f $bak)
  Detail ("journal     ：{0} 条 ops -> {1}" -f @($script:state.ops).Count, $StateFile)
  Exit-Stage

  # ---------- Stage 9：重启生效 ----------
  Enter-Stage '重启 sshd 使配置生效'
  if (-not $script:ConfigChanged) {
    Ok '本次没有任何实际改动（全部幂等命中）-> 跳过重启，连接不受影响'
    Detail '重跑本脚本不会重复写配置/公钥/防火墙，也不会重复记 journal；历史条目与首次 baseline 原样保留'
    $final = Get-Service -Name sshd
    $listenOk = Test-Tcp -Target '127.0.0.1' -TcpPort $Port -TimeoutMs 2000
    if ($listenOk) { Ok ("本机回环 TCP {0} 可连" -f $Port) } else { Warn ("未连上本机 TCP {0}（服务状态 {1}）" -f $Port, $final.Status) }
    $noneState = Test-NoAuthAccepted -Target '127.0.0.1' -TcpPort $Port -UserName $User
    Write-NoneAuthVerdict $noneState
    Exit-Stage
  }
  Say '    注意：这一步会瞬断现有 SSH 连接（远程执行属正常现象）'
  Restart-Service -Name sshd -Force
  Start-Sleep -Seconds 2
  $final = Get-Service -Name sshd
  Ok ("重启后服务：{0}" -f $final.Status)
  $listenOk = Test-Tcp -Target '127.0.0.1' -TcpPort $Port -TimeoutMs 2000
  if ($listenOk) { Ok ("本机回环 TCP {0} 可连（监听正常）" -f $Port) }
  else { Warn ("未连上本机 TCP {0}（可能还需数秒；非标端口请确认防火墙）" -f $Port) }
  $noneState = Test-NoAuthAccepted -Target '127.0.0.1' -TcpPort $Port -UserName $User
  Write-NoneAuthVerdict $noneState
  Add-Op 'restart-service' @{ note = '重启以生效' } ([ordered]@{ type = 'restart_service' }) @{ status = [string]$final.Status; loopback = $listenOk } 'ok' 'sshd'
  Exit-Stage

  # ---------- 收尾 ----------
  Say ''
  Say '================================================================' 'Green'
  Ok '构建完成。回到宿主机执行：'
  Say ("   ssh -F /dev/null -i ~/.ssh/id_ed25519_winvm -o IdentitiesOnly=yes -o BatchMode=yes -p {0} {1}@{2} `"whoami & hostname`"" -f $Port, $User, $env:COMPUTERNAME) 'White'
  Say '================================================================' 'Green'
  Say ''
  Detail '账户密码未被修改；密码认证已保留（要关闭攻击面请加 -Harden 重跑）。'
  if ($script:EmptyUsed -eq 'yes') {
    Warn '空密码密码登录已放开（PermitEmptyPasswords yes + LimitBlankPasswordUse=0，已记 journal）'
    Warn '  注意：这同时打开了 none 匿名登录；非必需时去掉 -EmptyPasswordMode yes 重跑即可收回'
  } else {
    Detail '空密码账户只能走公钥（PermitEmptyPasswords no）；密码认证方法本身仍开启（PasswordAuthentication yes）'
  }
  Detail ("操作日志：{0} 条 -> {1}" -f @($script:state.ops).Count, $StateFile)
  Detail ("本次运行日志：{0}" -f $script:LogFile)
  Say ''
  if ($script:SelfStaged) {
    Info '随时可做的三件事：'
    Say ('   powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script:SelfPathFinal + '" -Continue          # 只读体检') 'White'
    Say ('   powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script:SelfPathFinal + '" -Rollback -DryRun  # 预演回滚') 'White'
    Say ('   powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script:SelfPathFinal + '" -Rollback          # 真回滚') 'White'
  } else {
    Warn ('脚本未能自落盘（selfstage=none）⇒ 将来没有确定的 -Rollback 可执行文件。')
    Warn ('请立刻把内存里的脚本文本另存为 C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1，或用 -SelfUrl <直链> 重跑。')
  }
  Say ''
}
catch {
  $e = $_
  $msg = 'unknown error'
  try { $msg = ($e.Exception.Message -split "`n")[0] } catch {}

  Say ''
  Say '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' 'Red'
  Err ("执行中断：{0}" -f $msg)
  Say ("    阶段：{0}/{1}  {2}" -f $script:StageIdx, $script:StageTotal, $script:StageName) 'Red'
  try {
    $pos = [string]$e.InvocationInfo.PositionMessage
    Say ("    位置：{0}" -f ($pos -replace "`r?`n", ' ')) 'Red'
  } catch {}

  $errFile = ''
  try {
    # DryRun / 干净环境下不往 C:\ProgramData 写东西，错误报告改落 %TEMP%
    $errDir = $env:TEMP
    if (-not $dryRunMode -and (Test-Path $LogDir)) { $errDir = $LogDir }
    if (-not (Test-Path $errDir)) { New-Item -ItemType Directory -Force -Path $errDir | Out-Null }
    $errFile = Join-Path $errDir ("wb-tunnel-error-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $body = New-Object 'System.Collections.Generic.List[string]'
    $body.Add('================ wb-tunnel error report ================')
    $body.Add(("time       : {0}" -f (Get-Date -Format 'o')))
    $body.Add(("script     : {0}  v{1}  sha={2}" -f $script:SelfPath, $SCRIPT_VERSION, $script:SelfSha))
    $body.Add(("mode       : {0}   dryRun={1}" -f $script:Mode, $dryRunMode))
    $body.Add(("stage      : {0}/{1} {2}" -f $script:StageIdx, $script:StageTotal, $script:StageName))
    $body.Add(("host/user  : {0} / {1}   admin={2}   ps={3}" -f $env:COMPUTERNAME, $env:USERNAME, $script:IsAdmin, $PSVersionTable.PSVersion))
    $body.Add(("params     : user={0} port={1} harden={2} skipInstall={3}" -f $User, $Port, $doHarden, $SkipInstall))
    $body.Add('')
    $body.Add('---- 异常 ----')
    try { $body.Add($e.Exception.ToString()) } catch { $body.Add($msg) }
    try {
      if ($e.ScriptStackTrace) { $body.Add('---- 调用栈 ----'); $body.Add([string]$e.ScriptStackTrace) }
    } catch {}
    try {
      if ($e.InvocationInfo.PositionMessage) { $body.Add('---- 出错位置 ----'); $body.Add([string]$e.InvocationInfo.PositionMessage) }
    } catch {}
    try {
      if ($e.CategoryInfo) { $body.Add('---- 分类 ----'); $body.Add([string]$e.CategoryInfo) }
    } catch {}
    $body.Add('')
    $body.Add('---- 本次日志尾部 80 行 ----')
    if ($script:LogFile -and (Test-Path $script:LogFile)) {
      foreach ($l in @(Get-Content -Path $script:LogFile -Tail 80 -ErrorAction SilentlyContinue)) { $body.Add($l) }
    } else { $body.Add('(无日志文件)') }
    $body.Add('')
    $body.Add('---- journal ----')
    if (Test-Path $StateFile) {
      $raw = ''
      try { $raw = Get-Content -Path $StateFile -Raw -ErrorAction Stop } catch { $raw = '(读取失败)' }
      $body.Add($raw)
    } else { $body.Add('(无 journal)') }
    Set-Content -Path $errFile -Value $body -Encoding UTF8
  } catch { $errFile = '' }

  Write-Log 'ERROR' $msg
  if ($errFile) {
    Err ("错误报告已保存：{0}" -f $errFile)
    Say '    把这个文件的内容整段复制回来即可定位问题（含异常、堆栈、尾日志、journal）。' 'Yellow'
  } else {
    Warn '错误报告写入失败（可能是磁盘/权限问题），请复制上面的输出。'
  }
  Say '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' 'Red'
  Say ''
  Say '已做过的变更都记在 journal 里，随时可精确还原：' 'Yellow'
  if ($script:SelfStaged) {
    Say ('   powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script:SelfPathFinal + '" -Rollback -DryRun') 'White'
    Say ('   powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script:SelfPathFinal + '" -Continue') 'White'
  } else {
    Say ('   ⚠ 脚本未落盘。请先下载 oneclick 到 ' + $script:SelfPathFinal + ' 再执行 -Rollback') 'Red'
  }
  Say ''
}
