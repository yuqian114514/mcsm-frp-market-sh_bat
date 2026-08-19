
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

Write-Host ""
Write-Host "————————————————————————————————————————————————" -ForegroundColor Cyan
Write-Host ""
Write-Host "      MCSM FRP 模板集市 - *ChmlfFrp*" -ForegroundColor Cyan
Write-Host "                 作者: 语千🍥" -ForegroundColor Cyan
Write-Host "              QQ交流群: 941830180" -ForegroundColor Cyan
Write-Host ""
Write-Host "————————————————————————————————————————————————" -ForegroundColor Cyan
Write-Host ""

$Platform = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'windows_amd64' }; 'ARM64' { 'windows_arm64' }; 'x86' { 'windows_386' }; default { 'windows_amd64' } }

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[x] $m" -ForegroundColor Red }

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
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($StateXml)
    $node = $doc.SelectSingleNode("/state/$tag")
    if ($node) { return $node.InnerText }
    return ''
}

function Set-State($tag, $val) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($StateXml)
    $node = $doc.SelectSingleNode("/state/$tag")
    if (-not $node) {
        $node = $doc.CreateElement($tag)
        $doc.DocumentElement.AppendChild($node) | Out-Null
    }
    $node.InnerText = [string]$val
    $doc.Save($StateXml)
}

function Test-FirstRun {
    if (-not (Test-Path $StateXml)) { return $true }
    return [string]::IsNullOrEmpty((Get-State 'last_tunnel_id'))
}

function Invoke-DownloadWithFallback($GhPath, $OutFile) {
    $primary = "https://github.com/$GhPath"
    $mirror = "$GithubMirror/https://github.com/$GhPath"
    $mirror2 = "$GithubMirror2/https://github.com/$GhPath"
    $mirror3 = "$GithubMirror3/https://github.com/$GhPath"

    Info "尝试从 GitHub 下载: $primary"
    try {
        Invoke-WebRequest -Uri $primary -OutFile $OutFile -TimeoutSec 30 -UseBasicParsing
        Ok "GitHub 下载成功"
        return $true
    } catch {
        Warn "GitHub 下载失败，切换镜像站"
    }

    Info "镜像站下载: $mirror"
    try {
        Invoke-WebRequest -Uri $mirror -OutFile $OutFile -TimeoutSec 40 -UseBasicParsing
        Ok "镜像站下载成功"
        return $true
    } catch {
        Warn "下载失败，切换镜像站"
    }

    Info "镜像站下载: $mirror2"
    try {
        Invoke-WebRequest -Uri $mirror2 -OutFile $OutFile -TimeoutSec 40 -UseBasicParsing
        Ok "镜像站下载成功"
        return $true
    } catch {
        Warn "下载失败，切换镜像站"
    }

    Info "镜像站下载: $mirror3"
    try {
        Invoke-WebRequest -Uri $mirror3 -OutFile $OutFile -TimeoutSec 40 -UseBasicParsing
        Ok "镜像站下载成功"
        return $true
    } catch {
        Err "下载失败"
        return $false
    }
}

$ChmlApiBase      = 'https://cf-v2.uapis.cn'
$ChmlFrpRepo      = 'chmlfrp/chmlfrp'
$ChmlAuthorize    = 'https://account-api.qzhua.net/oauth2/authorize'
$ChmlTokenUrl     = 'https://account-api.qzhua.net/oauth2/token'
$ChmlUserInfoUrl  = 'https://account-api.qzhua.net/oauth2/userinfo'
$ChmlScope        = 'openid profile email phone offline_access chmlfrp_api'
$ChmlClientId     = '01a00af8728b79c6aae8488b76afbb15'
$ChmlFrpVersion   = '0.51.2_251023_2'
$ChmlDownloadBase = 'https://cf-v1.uapis.cn/download'

function ConvertTo-Base64Url([byte[]]$bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-PkceVerifier {
    $b = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    ConvertTo-Base64Url $b
}

function Get-PkceChallenge($verifier) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    ConvertTo-Base64Url $hash
}

function EnsureToken {
    $token = Get-State 'token'
    if (-not [string]::IsNullOrEmpty($token)) { return }

    $verifier  = New-PkceVerifier
    $challenge = Get-PkceChallenge $verifier
    $state     = [guid]::NewGuid().ToString('N')
    $nonce     = [guid]::NewGuid().ToString('N')

    Write-Host ''
    Write-Host '================ 授权方式 ================'
    Write-Host '  1) 本机运行 (自动打开浏览器并接收回调)'
    Write-Host '  2) 云服务器/远程 (手动把浏览器地址栏 URL 粘贴回来)'
    Write-Host '========================================='
    $mode = Read-Host '请选择授权方式 [默认 2]'
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = '2' }

    if ($mode -eq '2') {
        $RedirectUri = 'http://127.0.0.1:47902/callback'
        $authUrl = $ChmlAuthorize + '?response_type=code' +
                '&client_id=' + $ChmlClientId +
                '&redirect_uri=' + [uri]::EscapeDataString($RedirectUri) +
                '&scope=' + [uri]::EscapeDataString($ChmlScope) +
                '&state=' + $state +
                '&nonce=' + $nonce +
                '&code_challenge=' + $challenge +
                '&code_challenge_method=S256'

        Write-Host ''
        Write-Host '请在【你自己电脑】的浏览器中打开以下链接完成授权:' -ForegroundColor Yellow
        Write-Host "  $authUrl" -ForegroundColor Cyan
        Write-Host ''
        Write-Host '授权后浏览器会跳到 http://127.0.0.1:47902/callback?... 这个打不开的页面 (正常现象)' -ForegroundColor Yellow
        Write-Host '请把浏览器【地址栏里的完整 URL】整段复制, 粘贴到这里:' -ForegroundColor Yellow
        $callbackUrl = Read-Host '回调 URL'

        $code = $null
        $gotState = $null
        if ($callbackUrl -match 'code=([^&\s]+)')  { $code = $Matches[1] }
        if ($callbackUrl -match 'state=([^&\s]+)') { $gotState = $Matches[1] }
    } else {
        $RedirectUri = 'http://127.0.0.1:47902/callback'

        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 47902)
            $listener.Start()
        } catch {
            Err '端口 47902 被占用，请关闭占用该端口的程序后重试'
            exit 1
        }

        $authUrl = $ChmlAuthorize + '?response_type=code' +
                '&client_id=' + $ChmlClientId +
                '&redirect_uri=' + [uri]::EscapeDataString($RedirectUri) +
                '&scope=' + [uri]::EscapeDataString($ChmlScope) +
                '&state=' + $state +
                '&nonce=' + $nonce +
                '&code_challenge=' + $challenge +
                '&code_challenge_method=S256'

        Info "已在 $RedirectUri 等待授权回调..."
        Write-Host ""
        Write-Host "请在浏览器中打开以下链接完成授权:" -ForegroundColor Yellow
        Write-Host "  $authUrl" -ForegroundColor Cyan
        Write-Host ""

        try { Start-Process $authUrl } catch { }

        $code = $null
        $gotState = $null
        try {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $sb = New-Object System.Text.StringBuilder
            $buf = New-Object byte[] 1
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
            $stream.Write($rb,0,$rb.Length)
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush()
            $stream.Close()
            $client.Close()
        } catch {
        } finally {
            $listener.Stop()
        }
    }

    if ([string]::IsNullOrEmpty($code)) { Err '未获取到授权 code'; exit 1 }
    if ($gotState -ne $state) { Err 'state 不匹配, 已中止'; exit 1 }

    Info '正在用 code 换取 access_token...'
    $body = @{
        grant_type='authorization_code'
        code=$code
        redirect_uri=$RedirectUri
        client_id=$ChmlClientId
        code_verifier=$verifier
    }
    try {
        $tk = Invoke-RestMethod -Method Post -Uri $ChmlTokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 20
        $access = if ($tk.access_token) { $tk.access_token } else { $tk.data.access_token }
        $refresh = if ($tk.refresh_token) { $tk.refresh_token } else { $tk.data.refresh_token }
        if ([string]::IsNullOrEmpty($access)) { Err "换取 token 失败"; exit 1 }
        Set-State 'token' $access
        if ($refresh) { Set-State 'refresh_token' $refresh }
        Ok 'OAuth 登录成功'
    } catch {
        Err "换取 token 失败: $_"
        exit 1
    }
}

function FetchTunnels {
    $token = Get-State 'token'
    $uri = $ChmlApiBase + '/tunnel?token=' + $token
    Info "请求 API: $uri"
    try {
        # 获取原始字节，然后用 UTF-8 解码
        $webClient = New-Object System.Net.WebClient
        $webClient.Encoding = [System.Text.Encoding]::UTF8
        $jsonText = $webClient.DownloadString($uri)
        $resp = $jsonText | ConvertFrom-Json

        if ($resp.state -ne 'success') {
            Warn "Token 可能过期或无效, 响应状态: $($resp.state)"
            Set-State 'token' ''
            EnsureToken
            return (FetchTunnels)
        }
        if ($resp.data) {
            $result = @($resp.data)
            Info "成功获取 $($result.Count) 个隧道"
            return $result
        }
        return @()
    } catch {
        Err "获取隧道列表失败: $_"
        Err "错误详情: $($_.Exception.Message)"

        if ($_.Exception.Message -like "*未能解析*" -or $_.Exception.Message -like "*could not be resolved*") {
            Err "DNS 解析失败，请检查网络连接或更换 DNS 服务器"
            Err "当前 API 地址: $ChmlApiBase"
        }

        return @()
    }
}

function GetFrpcConfig($tunnelName, $nodeName) {
    $token = Get-State 'token'
    $cfg = Join-Path $DataDir "frpc_$tunnelName.ini"
    $uri = $ChmlApiBase + '/tunnel_config?token=' + $token + '&node=' + $nodeName + '&tunnel_names=' + $tunnelName
    try {
        # 获取原始字节，然后用 UTF-8 解码
        $webClient = New-Object System.Net.WebClient
        $webClient.Encoding = [System.Text.Encoding]::UTF8
        $jsonText = $webClient.DownloadString($uri)
        $resp = $jsonText | ConvertFrom-Json

        if ($resp.state -ne 'success') {
            Err "获取配置失败: $($resp.msg)"
            return $null
        }
        [System.IO.File]::WriteAllText($cfg, $resp.data, (New-Object System.Text.UTF8Encoding($false)))
        return $cfg
    } catch {
        Err "获取配置失败: $_"
        return $null
    }
}



function GetLatestVersion {
    return $ChmlFrpVersion
}

function Get-FrpcBin {
    Join-Path $FrpDir 'frpc.exe'
}

function Install-Frp($tag) {
    $asset = "ChmlFrp-${tag}_${Platform}.zip"
    $downloadUrl = "$ChmlDownloadBase/$asset"
    $tmp = Join-Path $DataDir $asset
    Info "下载 frp $tag ($asset)"
    Info "下载地址: $downloadUrl"

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tmp -TimeoutSec 60 -UseBasicParsing
        Ok "下载成功"
    } catch {
        Err "下载失败: $_"
        return $false
    }

    Info '解压中...'
    $extract = Join-Path $DataDir 'frp_extract'
    if (Test-Path $extract) {
        Remove-Item -Recurse -Force $extract
    }
    try {
        Expand-Archive -Path $tmp -DestinationPath $extract -Force
        $found = Get-ChildItem -Path $extract -Recurse -File | Where-Object { $_.Name -match '^(frpc|chmlfrp)\.exe$' } | Select-Object -First 1
        if (-not $found) {
            Err '压缩包内未找到 frpc.exe'
            return $false
        }
        Copy-Item $found.FullName (Get-FrpcBin) -Force
        Remove-Item -Force $tmp
        Remove-Item -Recurse -Force $extract
        Set-State 'frp_version' $tag
        Ok "frp 已安装: $tag"
        return $true
    } catch {
        Err "安装失败: $_"
        return $false
    }
}

function Update-Frp {
    $latest = GetLatestVersion
    $current = Get-State 'frp_version'

    if (-not (Test-Path (Get-FrpcBin))) {
        Info '首次启动，安装 frp...'
        Install-Frp $latest | Out-Null
        return
    }

    if ($latest -ne $current) {
        Warn "发现新版本 frp: $current -> $latest，正在更新"
        Install-Frp $latest | Out-Null
        return
    }

    Ok "frp 已是最新版: $current"
}

function Select-Tunnel {
    Info '获取隧道列表...'
    $tunnels = @(FetchTunnels)  # 强制转换为数组

    # 调试信息
    Info "隧道数量: $($tunnels.Count)"
    if ($tunnels.Count -gt 0) {
        Info "隧道类型: $($tunnels.GetType().Name)"
        Info "第一个隧道: id=$($tunnels[0].id), name=$($tunnels[0].name)"
    }

    if (-not $tunnels -or $tunnels.Count -eq 0) {
        Err '未获取到隧道'
        return $null
    }

    Write-Host ''
    Write-Host '================ 隧道列表 ================'
    for ($i = 0; $i -lt $tunnels.Count; $i++) {
        $t = $tunnels[$i]
        $status = if ($t.state -eq 'false') { '离线' } else { '在线' }
        '{0,2}) [id:{1}] {2,-20} [{3}] {4} -> {5}:{6} ({7})' -f ($i+1), $t.id, $t.name, $t.type, $t.node, $t.ip, $t.dorp, $status | Write-Host
    }
    Write-Host '========================================='
    while ($true) {
        $c = Read-Host '选择隧道编号'
        if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $tunnels.Count) {
            return $tunnels[[int]$c - 1]
        }
        Warn '输入无效，请重试'
    }
}



function Start-Tunnel($tunnel) {
    $tid = $tunnel.id
    $tname = $tunnel.name
    $node = $tunnel.node
    Info "获取隧道 [$tname] 的配置..."
    $cfg = GetFrpcConfig $tname $node
    if (-not $cfg) { return }
    $bin = Get-FrpcBin
    Set-State 'last_tunnel_id' $tid
    Set-State 'last_tunnel_name' $tname
    Ok "启动隧道: $tname"
    Write-Host "执行: `"$bin`" -c `"$cfg`""
    Write-Host '------------------------------------------'
    & $bin -c $cfg
}

function Start-Last {
    $tid = Get-State 'last_tunnel_id'
    if ([string]::IsNullOrEmpty($tid)) {
        Warn '没有历史隧道记录'
        return
    }
    $tname = Get-State 'last_tunnel_name'
    $tunnels = FetchTunnels
    $tunnel = $tunnels | Where-Object { $_.id -eq $tid } | Select-Object -First 1
    if (-not $tunnel) {
        Warn "未找到隧道 id=$tid，请重新选择"
        $t = Select-Tunnel
        if ($t) { Start-Tunnel $t }
        return
    }
    Start-Tunnel $tunnel
}

function Invoke-FirstRun {
    EnsureToken
    Update-Frp
    $t = Select-Tunnel
    if ($t) { Start-Tunnel $t }
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
        '2' { EnsureToken; Update-Frp; $t = Select-Tunnel; if ($t) { Start-Tunnel $t } }
        '0' { Info '退出'; return }
        default { Warn '无效选择' }
    }
}

Initialize-State
if (Test-FirstRun) { Invoke-FirstRun } else { Invoke-Returning }