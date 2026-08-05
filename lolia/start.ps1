#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

try { chcp 65001 > $null; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataDir   = Join-Path $ScriptDir 'data'
$FrpDir    = Join-Path $ScriptDir 'frp'
$StateXml  = Join-Path $DataDir 'state.xml'
$GithubMirror = 'https://github.nswrz.cn'
$GithubMirror2 = 'https://ghfile.geekertao.top'
$GithubMirror3 = 'https://github.tbap.top'


New-Item -ItemType Directory -Force -Path $DataDir, $FrpDir | Out-Null

# ---- Banner ----
  Write-Host ""
  Write-Host "————————————————————————————————————————————————" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "      MCSM FRP 模板集市 - *Lolia-FRP*" -ForegroundColor Cyan
  Write-Host "                 作者: 语千🍥" -ForegroundColor Cyan
  Write-Host "              QQ交流群: 941830180" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "————————————————————————————————————————————————" -ForegroundColor Cyan
  Write-Host ""


$Platform = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'windows_amd64' }; 'ARM64' { 'windows_arm64' }; 'x86' { 'windows_386' }; default { 'windows_amd64' } }

# ---- 输出 ----
function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[x] $m" -ForegroundColor Red }

# ---- XML 状态 ----
function Initialize-State {
  if (Test-Path $StateXml) { return }
  $doc = New-Object System.Xml.XmlDocument
  $doc.AppendChild($doc.CreateXmlDeclaration('1.0','UTF-8',$null)) | Out-Null
  $root = $doc.CreateElement('state')
  foreach ($t in 'token','refresh_token','last_tunnel_id','last_tunnel_name','last_command','frp_version') {
    $root.AppendChild($doc.CreateElement($t)) | Out-Null
  }
  $doc.AppendChild($root) | Out-Null
  $doc.Save($StateXml)
}
function Get-State($tag) {
  if (-not (Test-Path $StateXml)) { return '' }
  $doc = New-Object System.Xml.XmlDocument; $doc.Load($StateXml)
  $node = $doc.SelectSingleNode("/state/$tag")
  if ($node) { return $node.InnerText } else { return '' }
}
function Set-State($tag, $val) {
  $doc = New-Object System.Xml.XmlDocument; $doc.Load($StateXml)
  $node = $doc.SelectSingleNode("/state/$tag")
  if (-not $node) { $node = $doc.CreateElement($tag); $doc.DocumentElement.AppendChild($node) | Out-Null }
  $node.InnerText = [string]$val; $doc.Save($StateXml)
}
function Test-FirstRun {
  if (-not (Test-Path $StateXml)) { return $true }
  return [string]::IsNullOrEmpty((Get-State 'last_tunnel_id'))
}

# ---- 下载 ----
function Invoke-DownloadWithFallback($GhPath, $OutFile) {
  $primary = "https://github.com/$GhPath"; $mirror = "$GithubMirror/https://github.com/$GhPath"; $mirror2 = "$GithubMirror2/https://github.com/$GhPath"; $mirror3 = "$GithubMirror3/https://github.com/$GhPath"
  Info "尝试从 GitHub 下载: $primary"
  try { Invoke-WebRequest -Uri $primary -OutFile $OutFile -TimeoutSec 30 -UseBasicParsing; Ok "GitHub 下载成功"; return $true }
  catch { Warn "GitHub 下载失败，切换镜像站" }
  Info "镜像站下载: $mirror"
  try { Invoke-WebRequest -Uri $mirror -OutFile $OutFile -TimeoutSec 40 -UseBasicParsing; Ok "镜像站下载成功"; return $true }
  catch { Warn "下载失败，切换镜像站" }
  Info "镜像站下载: $mirror2"
  try { Invoke-WebRequest -Uri $mirror2 -OutFile $OutFile -TimeoutSec 40 -UseBasicParsing; Ok "镜像站下载成功"; return $true }
  catch { Warn "下载失败，切换镜像站" }
  Info "镜像站下载: $mirror3"
  try { Invoke-WebRequest -Uri $mirror3 -OutFile $OutFile -TimeoutSec 40 -UseBasicParsing; Ok "镜像站下载成功"; return $true }
  catch { Err "下载失败"; return $false }
}

# ---- Lolia 配置 ----
$LoliaApiBase   = 'https://api.lolia.link/api/v1'
$LoliaFrpRepo   = 'Lolia-FRP/lolia-frp'
$LoliaAuthorize = 'https://dash.lolia.link/oauth/authorize'
$LoliaTokenUrl  = 'https://api.lolia.link/api/v1/oauth2/token'
$LoliaScope     = 'user:read tunnel:read node:read'
$LoliaClientId  = 'xv1fzjdeuahur235'


# ---- PKCE 工具 ----
function ConvertTo-Base64Url([byte[]]$bytes) { [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
function New-PkceVerifier {
  $b = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  ConvertTo-Base64Url $b
}
function Get-PkceChallenge($verifier) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
  ConvertTo-Base64Url $hash
}

# ---- OAuth2 + PKCE 登录 ----
function EnsureToken {
  $token = Get-State 'token'
  if (-not [string]::IsNullOrEmpty($token)) { return }

  $verifier  = New-PkceVerifier
  $challenge = Get-PkceChallenge $verifier
  $state     = [guid]::NewGuid().ToString('N')

  # 先自动找空闲端口 (11451-11460), 再拼 authUrl, 保证端口一致
  $listener = $null
  $port = 11451
  while ($port -le 11460) {
    try {
      $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
      $listener.Start()
      break
    } catch {
      $port++
    }
  }
  if (-not $listener) { Err '无法找到可用端口 (11451-11460 均被占用)'; exit 1 }

  $RedirectPort = $port
  $RedirectUri  = "http://127.0.0.1:$RedirectPort/callback"

  # authUrl 必须在端口确定后拼接, redirect_uri 用同一个 $RedirectUri
  $authUrl = "https://dash.lolia.link/oauth/authorize?response_type=code" +
             "&client_id=" + $LoliaClientId +
             "&redirect_uri=" + [uri]::EscapeDataString($RedirectUri) +
             "&scope=" + [uri]::EscapeDataString($LoliaScope) +
             "&state=" + $state +
             "&code_challenge=" + $challenge +
             "&code_challenge_method=S256"

  Info "已在 $RedirectUri 等待授权回调..."
  Write-Host ""
  Write-Host "请在浏览器中打开以下链接完成授权:" -ForegroundColor Yellow
  Write-Host "  $authUrl" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "授权完成后, 浏览器会跳转到 $RedirectUri 显示授权成功喵页面" -ForegroundColor Yellow
  Write-Host "如果跳转失败（页面打不开）, 请检查 $RedirectUri 是否被占用" -ForegroundColor Yellow
  Write-Host ""

  $code = $null; $gotState = $null
  try {
    $client = $listener.AcceptTcpClient(); $stream = $client.GetStream()
    $sb = New-Object System.Text.StringBuilder; $buf = New-Object byte[] 1
    while ($true) {
      if ($stream.Read($buf,0,1) -le 0) { break }
      $ch = [char]$buf[0]
      if ($ch -eq "`n") { break }
      if ($ch -ne "`r") { [void]$sb.Append($ch) }
      if ($sb.Length -gt 8192) { break }
    }
    $line = $sb.ToString()
    if ($line -match 'code=([^&\s]+)')  { $code = $Matches[1] }
    if ($line -match 'state=([^&\s]+)') { $gotState = $Matches[1] }
    $html = "<!doctype html><meta charset='utf-8'><h2>授权成功喵</h2><p>可以关闭本页返回终端了。</p>"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $resp = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
    $rb = [System.Text.Encoding]::ASCII.GetBytes($resp)
    $stream.Write($rb,0,$rb.Length); $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
    $stream.Close(); $client.Close()
  } finally { $listener.Stop() }

  if ([string]::IsNullOrEmpty($code)) { Err '未获取到授权 code'; exit 1 }
  if ($gotState -ne $state) { Err 'state 不匹配, 已中止'; exit 1 }

  Info '正在用 code 换取 access_token...'
  $body = @{ grant_type='authorization_code'; code=$code; redirect_uri=$RedirectUri; client_id=$LoliaClientId; code_verifier=$verifier }
  $tk = Invoke-RestMethod -Method Post -Uri $LoliaTokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 20
  $access = if ($tk.access_token) { $tk.access_token } else { $tk.data.access_token }
  $refresh = if ($tk.refresh_token) { $tk.refresh_token } else { $tk.data.refresh_token }
  if ([string]::IsNullOrEmpty($access)) { Err "换取 token 失败: $($tk | ConvertTo-Json -Compress)"; exit 1 }
  Set-State 'token' $access
  if ($refresh) { Set-State 'refresh_token' $refresh }
  Ok 'OAuth 登录成功'
}

# ---- 隧道操作 ----
function FetchTunnels {
  $token = Get-State 'token'; $headers = @{ Authorization = "Bearer $token" }
  $result = @(); $page = 1; $totalPage = 1
  do {
    $uri = "$LoliaApiBase/user/tunnel?page=$page" + "&" + "limit=50"
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 20
    if ($resp.code -eq 401) { Warn 'Token 过期或无效，重新登录'; Set-State 'token' ''; EnsureToken; return (FetchTunnels) }
    foreach ($t in $resp.data.list) {
      $result += [pscustomobject]@{ Id=$t.id; Name=$t.name; Extra="[$($t.type)] $($t.node_name)  :$($t.remote_port)  ($($t.remark))  $($t.status)" }
    }
    $totalPage = [int]$resp.data.total_page; $page++
  } while ($page -le $totalPage)
  return $result
}

function GetFrpcConfig($tid) {
  $token = Get-State 'token'; $cfg = Join-Path $DataDir "frpc_$tid.toml"
  $uri = "$LoliaApiBase/user/frpc/config?tunnel=$tid"
  $headers = @{ Authorization = "Bearer $token" }
  $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 20
  if ($resp.code -ne 200) { Err "获取配置失败: $($resp.msg)"; return $null }
  [System.IO.File]::WriteAllText($cfg, $resp.data.config, (New-Object System.Text.UTF8Encoding($false)))
  return $cfg
}

function GetLatestVersion {
  try { $resp = Invoke-RestMethod -Uri "$LoliaApiBase/client/version" -TimeoutSec 15; return $resp.data.tag } catch { return '' }
}

# 调隧道详情接口拿 tunnel_token (frpc -t 用的就是它, 不是 OAuth token)
function Get-TunnelToken($tname) {
  $token = Get-State 'token'; $headers = @{ Authorization = "Bearer $token" }
  $uri = "$LoliaApiBase/user/tunnel/$tname"
  $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 20
  return $resp.data.tunnel_token
}

# ---- frp 管理 ----
function Get-FrpcBin { Join-Path $FrpDir 'frpc.exe' }

function Install-Frp($tag) {
  $asset = "LoliaFrp_$Platform.zip"
  $ghPath = "$LoliaFrpRepo/releases/download/$tag/$asset"
  $tmp = Join-Path $DataDir $asset
  Info "下载 frp $tag ($asset)"
  if (-not (Invoke-DownloadWithFallback $ghPath $tmp)) { return $false }
  Info '解压中...'
  $extract = Join-Path $DataDir 'frp_extract'
  if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
  Expand-Archive -Path $tmp -DestinationPath $extract -Force
  $found = Get-ChildItem -Path $extract -Recurse -File | Where-Object { $_.Name -match '^(frpc|loliafrp.*)\.exe$' } | Select-Object -First 1
  if (-not $found) { Err '压缩包内未找到 frpc.exe'; return $false }
  Copy-Item $found.FullName (Get-FrpcBin) -Force
  Remove-Item -Force $tmp; Remove-Item -Recurse -Force $extract
  Set-State 'frp_version' $tag
  Ok "frp 已安装: $tag"
  return $true
}

function Update-Frp {
  $latest = GetLatestVersion; $current = Get-State 'frp_version'
  if (-not (Test-Path (Get-FrpcBin))) {
    Info '首次启动，安装 frp...'; if ([string]::IsNullOrEmpty($latest)) { Err '无法获取 frp 最新版本'; return }
    Install-Frp $latest | Out-Null; return
  }
  if (-not [string]::IsNullOrEmpty($latest) -and $latest -ne $current) {
    Warn "发现新版本 frp: $current -> $latest，正在更新"; Install-Frp $latest | Out-Null
  } else { Ok "frp 已是最新版: $current" }
}

# ---- TUI 选择隧道 ----
function Select-Tunnel {
  Info '获取隧道列表...'
  $tunnels = FetchTunnels
  if (-not $tunnels -or $tunnels.Count -eq 0) { Err '未获取到隧道 (检查 token 或网络)'; return $null }
  Write-Host ''; Write-Host '================ 隧道列表 ================'
  for ($i = 0; $i -lt $tunnels.Count; $i++) {
    '{0,2}) [id:{1}] {2,-24} {3}' -f ($i+1), $tunnels[$i].Id, $tunnels[$i].Name, $tunnels[$i].Extra | Write-Host
  }
  Write-Host '========================================='
  while ($true) {
    $c = Read-Host '选择隧道编号'
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $tunnels.Count) { return $tunnels[[int]$c - 1] }
    Warn '输入无效，请重试'
  }
}

# ---- 启动隧道 ----
function Start-Tunnel($tid, $tname) {
  Info "获取隧道 [$tname] 的令牌..."
  $utoken = Get-TunnelToken $tname
  if ([string]::IsNullOrEmpty($utoken)) { Err '获取隧道令牌失败'; return }
  $bin = Get-FrpcBin
  $arg = "${tid}:${utoken}"
  $cmd = "`"$bin`" -t `"$arg`""
  Set-State 'last_tunnel_id' $tid; Set-State 'last_tunnel_name' $tname; Set-State 'last_command' $cmd
  Ok "启动隧道: $tname"; Write-Host "执行: `"$bin`" -t ${tid}:***"; Write-Host '------------------------------------------'
  & $bin -t $arg
}

function Start-Last {
  $tid = Get-State 'last_tunnel_id'
  if ([string]::IsNullOrEmpty($tid)) { Warn '没有历史隧道记录'; return }
  $tname = Get-State 'last_tunnel_name'; Start-Tunnel $tid $tname
}

# ---- 主流程 ----
function Invoke-FirstRun {
  EnsureToken
  Update-Frp
  $t = Select-Tunnel
  if ($t) { Start-Tunnel $t.Id $t.Name }
}

function Invoke-Returning {
  Write-Host ''
  Write-Host '==================================='
  Write-Host " 上次隧道: $(Get-State 'last_tunnel_name')"
  Write-Host '==================================='
  Write-Host '  1) 启动上一次的隧道'
  Write-Host '  2) 切换隧道'
  Write-Host '  0) 退出'
  Write-Host '==================================='
  $c = Read-Host '请选择'
  switch ($c) {
    '1' { EnsureToken; Update-Frp; Start-Last }
    '2' { EnsureToken; Update-Frp; $t = Select-Tunnel; if ($t) { Start-Tunnel $t.Id $t.Name } }
    '0' { Info '退出'; return }
    default { Warn '无效选择' }
  }
}

# ---- 入口 ----
Initialize-State
if (Test-FirstRun) { Invoke-FirstRun } else { Invoke-Returning }
