
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

# 强制启用 TLS 1.2/1.3
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
} catch {}

# 设置控制台编码
try {
  chcp 65001 > $null
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataDir = Join-Path $ScriptDir "data"
$FrpDir = Join-Path $ScriptDir "frp"
$StateXml = Join-Path $DataDir "state.xml"
$ApiBase = "https://api.mefrp.com/api"
$AlistApiBase = "https://drive.mcsl.com.cn/api"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:153.0) Gecko/20100101 Firefox/153.0"
$Origin = "https://www.mefrp.com"
$Referer = "https://www.mefrp.com/"

New-Item -ItemType Directory -Force -Path $DataDir, $FrpDir | Out-Null

Write-Host ""
Write-Host "-----------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "      MCSM FRP Template - MEFrp Launcher" -ForegroundColor Cyan
Write-Host "                 Author: YuQian" -ForegroundColor Cyan
Write-Host "              QQ Group: 941830180" -ForegroundColor Cyan
Write-Host ""
Write-Host "-----------------------------------------------" -ForegroundColor Cyan
Write-Host ""

function Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Err([string]$m)  { Write-Host "[x] $m" -ForegroundColor Red }

# ============================================================
# 状态持久化
# ============================================================
function Initialize-State {
  if (Test-Path $StateXml) { return }
  $doc = New-Object System.Xml.XmlDocument
  $doc.AppendChild($doc.CreateXmlDeclaration("1.0", "UTF-8", $null)) | Out-Null
  $root = $doc.CreateElement("state")
  foreach ($tag in "token", "refresh_token", "last_proxy_id", "last_proxy_name", "frp_version", "last_config") {
    $root.AppendChild($doc.CreateElement($tag)) | Out-Null
  }
  $doc.AppendChild($root) | Out-Null
  $doc.Save($StateXml)
}

function Get-State([string]$tag) {
  if (-not (Test-Path $StateXml)) { return "" }
  $doc = New-Object System.Xml.XmlDocument
  $doc.Load($StateXml)
  $node = $doc.SelectSingleNode("/state/$tag")
  if ($node) { return $node.InnerText }
  return ""
}

function Set-State([string]$tag, [string]$val) {
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

# ============================================================
# API 调用
# ============================================================
function New-MefrpHeaders {
  $token = Get-State "token"
  $headers = @{
    "User-Agent" = $UserAgent
    Origin = $Origin
    Referer = $Referer
    Accept = "application/json, text/plain, */*"
  }
  if (-not [string]::IsNullOrWhiteSpace($token)) {
    $headers["Authorization"] = "Bearer $token"
  }
  return $headers
}

function Invoke-MefrpGet([string]$Path) {
  Invoke-RestMethod -Method Get -Uri ($ApiBase + $Path) -Headers (New-MefrpHeaders) -TimeoutSec 30
}

function Invoke-MefrpPost([string]$Path, [object]$Body) {
  $json = $Body | ConvertTo-Json -Depth 20
  Invoke-RestMethod -Method Post -Uri ($ApiBase + $Path) -Headers (New-MefrpHeaders) -ContentType "application/json" -Body $json -TimeoutSec 30
}

# ============================================================
# 登录
# ============================================================
function Get-LoginHtml([int]$port) {
  return @"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>MEFrp 登录</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .container {
      background: white;
      border-radius: 12px;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      padding: 40px;
      max-width: 500px;
      width: 100%;
    }
    h1 {
      color: #667eea;
      margin-bottom: 10px;
      font-size: 28px;
    }
    .subtitle {
      color: #666;
      margin-bottom: 30px;
      font-size: 14px;
    }
    .form-group {
      margin-bottom: 20px;
    }
    label {
      display: block;
      margin-bottom: 8px;
      color: #333;
      font-weight: 500;
      font-size: 14px;
    }
    input {
      width: 100%;
      padding: 12px 16px;
      border: 2px solid #e1e8ed;
      border-radius: 8px;
      font-size: 14px;
      transition: all 0.3s;
    }
    input:focus {
      outline: none;
      border-color: #667eea;
      box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
    }
    button {
      width: 100%;
      padding: 14px;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      border: none;
      border-radius: 8px;
      font-size: 16px;
      font-weight: 600;
      cursor: pointer;
      transition: transform 0.2s, box-shadow 0.2s;
    }
    button:hover:not(:disabled) {
      transform: translateY(-2px);
      box-shadow: 0 8px 20px rgba(102, 126, 234, 0.4);
    }
    button:disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }
    .back-btn {
      background: #999;
      margin-top: 10px;
    }
    .back-btn:hover:not(:disabled) {
      box-shadow: 0 8px 20px rgba(153, 153, 153, 0.4);
    }
    .info {
      background: #f0f4ff;
      border-left: 4px solid #667eea;
      padding: 12px 16px;
      margin-bottom: 20px;
      border-radius: 4px;
      font-size: 13px;
      color: #555;
      line-height: 1.6;
    }
    .error {
      background: #ffe0e0;
      border-left: 4px solid #ff4444;
      padding: 12px 16px;
      margin-bottom: 20px;
      border-radius: 4px;
      font-size: 13px;
      color: #cc0000;
      display: none;
    }
    .success {
      background: #e0ffe0;
      border-left: 4px solid #44ff44;
      padding: 12px 16px;
      margin-bottom: 20px;
      border-radius: 4px;
      font-size: 13px;
      color: #008800;
      display: none;
    }
    .step {
      display: none;
    }
    .step.active {
      display: block;
    }
    .captcha-frame {
      width: 100%;
      height: 450px;
      border: 2px solid #e1e8ed;
      border-radius: 8px;
      margin-bottom: 15px;
    }
    .highlight {
      background: #fff3cd;
      padding: 2px 6px;
      border-radius: 3px;
      font-weight: 600;
      color: #856404;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>MEFrp 登录</h1>
    <p class="subtitle">MCSM FRP 模板集市 - MEFrp 启动器</p>
    
    <div id="error" class="error"></div>
    <div id="success" class="success">登录成功！正在跳转...</div>
    
    <div id="step1" class="step active">
      <form id="credentialsForm">
        <div class="form-group">
          <label for="username">用户名</label>
          <input type="text" id="username" name="username" placeholder="请输入用户名" required>
        </div>
        
        <div class="form-group">
          <label for="password">密码</label>
          <input type="password" id="password" name="password" placeholder="请输入密码" required>
        </div>
        
        <button type="submit" id="nextBtn">下一步：完成人机验证</button>
      </form>
    </div>

    <div id="step2" class="step">
      <div class="info">
        1. 在下方 iframe 中完成人机验证<br>
        2. 验证完成后，复制页面上显示的 <span class="highlight">验证码</span><br>
        3. 将验证码粘贴到下方文本框中<br>
        4. 点击"完成登录"按钮
      </div>
      
      <iframe id="captchaFrame" class="captcha-frame" src="https://www.mefrp.com/3rdparty/captcha?client=mcsmFRPTemplateMefrpLauncher"></iframe>
      
      <div class="form-group">
        <label for="captchaToken">验证码 Token</label>
        <input type="text" id="captchaToken" placeholder="请将上方验证码粘贴到此处" required>
      </div>
      
      <button id="loginBtn">完成登录</button>
      <button id="backBtn" class="back-btn">返回上一步</button>
    </div>
  </div>

  <script>
    const step1 = document.getElementById('step1');
    const step2 = document.getElementById('step2');
    const credentialsForm = document.getElementById('credentialsForm');
    const nextBtn = document.getElementById('nextBtn');
    const loginBtn = document.getElementById('loginBtn');
    const backBtn = document.getElementById('backBtn');
    const errorDiv = document.getElementById('error');
    const successDiv = document.getElementById('success');
    const captchaFrame = document.getElementById('captchaFrame');
    const captchaTokenInput = document.getElementById('captchaToken');

    let username = '';
    let password = '';

    credentialsForm.addEventListener('submit', (e) => {
      e.preventDefault();
      username = document.getElementById('username').value.trim();
      password = document.getElementById('password').value.trim();
      
      if (!username || !password) {
        showError('请输入用户名和密码');
        return;
      }

      errorDiv.style.display = 'none';
      step1.classList.remove('active');
      step2.classList.add('active');
    });

    backBtn.addEventListener('click', () => {
      step2.classList.remove('active');
      step1.classList.add('active');
      captchaTokenInput.value = '';
      captchaFrame.src = 'https://www.mefrp.com/3rdparty/captcha?client=mcsmFRPTemplateMefrpLauncher';
    });

    loginBtn.addEventListener('click', async () => {
      const captchaTokenRaw = captchaTokenInput.value.trim();
      
      if (!captchaTokenRaw) {
        showError('请输入验证码 Token');
        return;
      }

      loginBtn.disabled = true;
      loginBtn.textContent = '正在登录...';
      errorDiv.style.display = 'none';

      try {
        const response = await fetch('http://127.0.0.1:$port/login', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            username: username,
            password: password,
            captchaToken: captchaTokenRaw
          })
        });

        const result = await response.json();

        if (result.success) {
          successDiv.style.display = 'block';
          step2.style.display = 'none';
          setTimeout(() => window.close(), 2000);
        } else {
          showError(result.message || '登录失败，请检查用户名、密码和验证码');
          loginBtn.disabled = false;
          loginBtn.textContent = '完成登录';
        }
      } catch (err) {
        showError('登录失败：' + err.message);
        loginBtn.disabled = false;
        loginBtn.textContent = '完成登录';
      }
    });

    function showError(msg) {
      errorDiv.textContent = msg;
      errorDiv.style.display = 'block';
    }
  </script>
</body>
</html>
"@
}

function Start-LoginServer([int]$port) {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
  $listener.Start()

  $loginUrl = "http://127.0.0.1:$port"
  Info "登录服务器已启动：$loginUrl"
  Write-Host "正在打开浏览器进行登录..." -ForegroundColor Yellow
  try { Start-Process $loginUrl } catch {}

  $token = $null
  try {
    while (-not $token) {
      $client = $listener.AcceptTcpClient()
      $stream = $client.GetStream()
      $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

      $requestLine = $reader.ReadLine()
      $contentLength = 0

      while ($line = $reader.ReadLine()) {
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line -match "^Content-Length:\s*(\d+)") {
          $contentLength = [int]$Matches[1]
        }
      }

      if ($requestLine -match "POST /login ") {
        $buffer = New-Object char[] $contentLength
        [void]$reader.Read($buffer, 0, $contentLength)
        $body = -join $buffer

        $responseJson = ""
        try {
          $loginData = $body | ConvertFrom-Json

          Info "尝试登录用户：$($loginData.username)"

          $captchaToken = $loginData.captchaToken
          try {
            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($captchaToken))
            if ($decoded -match '^(.+)\|\|') {
              $captchaToken = $Matches[1]
            }
          } catch {}

          $loginBody = @{
            username = $loginData.username
            password = $loginData.password
            captchaToken = $captchaToken
          } | ConvertTo-Json -Compress

          $loginResp = Invoke-WebRequest -Method Post `
            -Uri ($ApiBase + '/public/login') `
            -Body $loginBody `
            -ContentType 'application/json' `
            -Headers @{
              'User-Agent' = $UserAgent
              'Origin' = $Origin
              'Referer' = $Referer
            } `
            -SessionVariable session `
            -TimeoutSec 30 `
            -UseBasicParsing

          $result = $loginResp.Content | ConvertFrom-Json

          if ($result.code -eq 200) {
            $foundToken = $null

            $setCookieHeaders = $loginResp.Headers['Set-Cookie']
            if ($setCookieHeaders) {
              foreach ($cookie in $setCookieHeaders) {
                if ($cookie -match 'token=([^;]+)') {
                  $foundToken = $Matches[1]
                  Info "从 Set-Cookie 头获取到 Token"
                  break
                }
              }
            }

            if (-not $foundToken) {
              $tokenCookie = $session.Cookies.GetCookies($ApiBase) | Where-Object { $_.Name -eq 'token' }
              if ($tokenCookie) {
                $foundToken = $tokenCookie.Value
                Info "从 Session Cookies 获取到 Token"
              }
            }

            if (-not $foundToken -and $result.data) {
              if ($result.data.token) {
                $foundToken = $result.data.token
                Info "从响应 data.token 获取到 Token"
              } elseif ($result.data.accessToken) {
                $foundToken = $result.data.accessToken
                Info "从响应 data.accessToken 获取到 Token"
              }
            }

            if ($foundToken) {
              $token = $foundToken
              Ok "登录成功，已获取 Token"
              $responseJson = '{"success":true,"message":"登录成功"}'
            } else {
              Warn "登录成功但无法获取 Token"
              $responseJson = '{"success":false,"message":"登录成功但无法获取 Token，建议使用手动登录方式"}'
            }
          } else {
            Err "登录失败：$($result.message)"
            $msg = $result.message -replace '"', '\"' -replace '\\', '\\'
            $responseJson = '{"success":false,"message":"' + $msg + '"}'
          }
        } catch {
          $errMsg = $_.Exception.Message -replace '"', '\"' -replace '\\', '\\'
          Err "登录异常：$errMsg"
          $responseJson = '{"success":false,"message":"登录失败: ' + $errMsg + '"}'
        }

        $fullResponse = "HTTP/1.1 200 OK`r`n"
        $fullResponse += "Content-Type: application/json; charset=utf-8`r`n"
        $fullResponse += "Access-Control-Allow-Origin: *`r`n"
        $fullResponse += "Connection: close`r`n"
        $fullResponse += "Content-Length: $([System.Text.Encoding]::UTF8.GetByteCount($responseJson))`r`n"
        $fullResponse += "`r`n"
        $fullResponse += $responseJson

        $fullBytes = [System.Text.Encoding]::UTF8.GetBytes($fullResponse)
        $stream.Write($fullBytes, 0, $fullBytes.Length)
        $stream.Flush()

      } elseif ($requestLine -match "GET / ") {
        $html = Get-LoginHtml $port

        $fullResponse = "HTTP/1.1 200 OK`r`n"
        $fullResponse += "Content-Type: text/html; charset=utf-8`r`n"
        $fullResponse += "Connection: close`r`n"
        $fullResponse += "Content-Length: $([System.Text.Encoding]::UTF8.GetByteCount($html))`r`n"
        $fullResponse += "`r`n"
        $fullResponse += $html

        $fullBytes = [System.Text.Encoding]::UTF8.GetBytes($fullResponse)
        $stream.Write($fullBytes, 0, $fullBytes.Length)
        $stream.Flush()

      } else {
        $fullResponse = "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        $fullBytes = [System.Text.Encoding]::UTF8.GetBytes($fullResponse)
        $stream.Write($fullBytes, 0, $fullBytes.Length)
        $stream.Flush()
      }

      Start-Sleep -Milliseconds 100
      $stream.Close()
      $client.Close()
    }
  } finally {
    $listener.Stop()
  }

  return $token
}

function Ensure-Token {
  $token = Get-State "token"
  if (-not [string]::IsNullOrWhiteSpace($token)) {
    try {
      $null = Invoke-MefrpGet "/auth/proxy/list"
      Ok "Token 有效"
      return
    } catch {
      Warn "Token 已过期，需要重新登录"
      Set-State "token" ""
    }
  }

  Write-Host ""
  Write-Host "================ 登录方式 ================"
  Write-Host "  1) 网页登录（自动打开浏览器，端口 11451-11459）"
  Write-Host "  2) 手动输入（直接粘贴 Token）"
  Write-Host "=========================================="
  $mode = Read-Host "请选择登录方式 [默认 1]"
  if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "1" }

  if ($mode -eq "2") {
    Write-Host ""
    Write-Host "从此处获取 Token：https://www.mefrp.com" -ForegroundColor Yellow
    $token = Read-Host "Token"
    if ([string]::IsNullOrWhiteSpace($token)) {
      Err "未提供 Token"
      exit 1
    }
  } else {
    $port = 11451
    $listener = $null
    while ($port -le 11459) {
      try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $listener.Stop()
        break
      } catch {
        $port++
      }
    }
    if ($port -gt 11459) {
      Err "无可用端口（11451-11459 全被占用）"
      exit 1
    }

    $token = Start-LoginServer $port
  }

  Set-State "token" $token
  try {
    $null = Invoke-MefrpGet "/auth/proxy/list"
    Ok "登录成功"
  } catch {
    Set-State "token" ""
    Err "Token 无效或已过期"
    exit 1
  }
}

# ============================================================
# 平台信息
# ============================================================
function Get-PlatformInfo {
  $os = "linux"
  if ($env:OS -like "*Windows*" -or $PSVersionTable.PSEdition -eq "Desktop") {
    $os = "windows"
  } elseif ($IsMacOS) {
    $os = "darwin"
  }

  $arch = "amd64"
  switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { $arch = "arm64" }
    "x86" { $arch = "386" }
  }

  [pscustomobject]@{ Os = $os; Arch = $arch }
}

function Get-FrpcPath {
  if ($env:OS -like "*Windows*" -or $PSVersionTable.PSEdition -eq "Desktop") {
    return (Join-Path $FrpDir "frpc.exe")
  }
  return (Join-Path $FrpDir "frpc")
}

# ============================================================
# Frpc 下载（模拟浏览器）
# ============================================================
function Resolve-FrpVersion {
  $token = Get-State "token"

  Info "正在获取最新版本信息..."

  try {
    $headers = @{
      Authorization = "Bearer $token"
      "User-Agent" = $UserAgent
      Origin = $Origin
      Referer = $Referer
      "Accept" = "application/json, text/plain, */*"
      "Sec-Fetch-Dest" = "empty"
      "Sec-Fetch-Mode" = "cors"
      "Sec-Fetch-Site" = "same-site"
    }

    $response = Invoke-WebRequest -Method Get `
      -Uri ($ApiBase + '/auth/products') `
      -Headers $headers `
      -TimeoutSec 30 `
      -UseBasicParsing

    $content = $response.Content

    if ($content -match '/ME-Frp/Local/MEFrp-Core/([^/"]+)/') {
      $version = $Matches[1]
      Ok "找到最新版本：$version"
      return $version
    }

    try {
      $data = $content | ConvertFrom-Json
      if ($data.data) {
        foreach ($item in $data.data) {
          if ($item.version) {
            Ok "找到最新版本：$($item.version)"
            return $item.version
          }
        }
      }
    } catch {}

  } catch {
    Warn "获取版本失败：$($_.Exception.Message)"
  }

  $manual = Read-Host "请输入 MEFrp 版本号（如 0.67.1_20260626_af59eefd）"
  if ([string]::IsNullOrWhiteSpace($manual)) {
    Err "无法解析版本号"
    exit 1
  }
  return $manual
}

function Get-AlistFileList([string]$version) {
  Info "正在获取文件列表..."

  try {
    $path = "/ME-Frp/Local/MEFrp-Core/$version"
    $uri = $AlistApiBase + "/fs/list?path=" + [uri]::EscapeDataString($path)

    $headers = @{
      "User-Agent" = $UserAgent
      "Accept" = "*/*"
      "Origin" = $Origin
      "Referer" = $Referer
      "Sec-Fetch-Dest" = "empty"
      "Sec-Fetch-Mode" = "cors"
      "Sec-Fetch-Site" = "cross-site"
    }

    $response = Invoke-RestMethod -Method Get `
      -Uri $uri `
      -Headers $headers `
      -TimeoutSec 30

    if ($response.code -eq 200 -and $response.data.content) {
      $files = @()

      foreach ($file in $response.data.content) {
        $name = $file.name
        if ($name -match '^mefrpc_' -and ($name -match '\.(zip|tar\.gz|tar)$')) {
          $files += [PSCustomObject]@{
            Name = $name
            Size = $file.size
          }
        }
      }

      if ($files.Count -eq 0) {
        Warn "未找到匹配的 mefrpc 文件"
        return $null
      }

      Ok "找到 $($files.Count) 个文件"
      return $files
    }

    Warn "Alist API 返回错误：$($response.message)"
    return $null

  } catch {
    Err "获取文件列表失败：$($_.Exception.Message)"
    return $null
  }
}

function Visit-FilePage([string]$version, [string]$filename) {
  try {
    $filePageUrl = "https://drive.mcsl.com.cn/ME-Frp/Local/MEFrp-Core/$version/$filename"

    $headers = @{
      "User-Agent" = $UserAgent
      "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
      "Referer" = "https://drive.mcsl.com.cn/ME-Frp/Local/MEFrp-Core/$version"
      "Sec-Fetch-Dest" = "document"
      "Sec-Fetch-Mode" = "navigate"
      "Sec-Fetch-Site" = "same-origin"
      "Upgrade-Insecure-Requests" = "1"
    }

    $null = Invoke-WebRequest -Method Get `
      -Uri $filePageUrl `
      -Headers $headers `
      -TimeoutSec 15 `
      -UseBasicParsing

    Start-Sleep -Milliseconds 1500
    Info "已访问文件页面"

  } catch {
    # 访问失败不影响下载
  }
}

function Download-FrpcFile([string]$version, [string]$filename, [string]$outputPath) {
  # 先访问文件页面
  Visit-FilePage $version $filename

  # 构建下载 URL
  $downloadUrl = "https://drive.mcsl.com.cn/d/ME-Frp/Local/MEFrp-Core/$version/$filename"

  Info "下载链接：$downloadUrl"

  $retries = 3
  for ($attempt = 1; $attempt -le $retries; $attempt++) {
    try {
      if ($attempt -gt 1) {
        Info "尝试下载（第 $attempt/$retries 次）..."
      }

      $headers = @{
        "User-Agent" = $UserAgent
        "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
        "Referer" = "https://drive.mcsl.com.cn/ME-Frp/Local/MEFrp-Core/$version/$filename"
        "Sec-Fetch-Dest" = "document"
        "Sec-Fetch-Mode" = "navigate"
        "Sec-Fetch-Site" = "same-origin"
        "Upgrade-Insecure-Requests" = "1"
      }

      # 确保目录存在
      $dir = Split-Path -Parent $outputPath
      if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
      }

      # 下载文件
      Invoke-WebRequest -Method Get `
        -Uri $downloadUrl `
        -OutFile $outputPath `
        -Headers $headers `
        -TimeoutSec 120 `
        -UseBasicParsing

      # 检查文件大小
      if (Test-Path $outputPath) {
        $fileSize = (Get-Item $outputPath).Length
        if ($fileSize -gt 100KB) {
          Ok "下载成功！文件大小：$([math]::Round($fileSize/1MB, 2)) MB"
          return $true
        } else {
          Warn "下载的文件太小（$fileSize 字节），可能是错误页面"
          Remove-Item $outputPath -Force
        }
      }

    } catch {
      Warn "下载失败：$($_.Exception.Message)"
      if (Test-Path $outputPath) {
        Remove-Item $outputPath -Force -ErrorAction SilentlyContinue
      }
    }

    if ($attempt -lt $retries) {
      $waitTime = 3 + ($attempt * 2)
      Info "等待 $waitTime 秒后重试..."
      Start-Sleep -Seconds $waitTime
    }
  }

  return $false
}

function Install-Frpc {
  $version = Resolve-FrpVersion
  if ([string]::IsNullOrWhiteSpace($version)) {
    Err "无法获取版本号"
    exit 1
  }

  $current = Get-State "frp_version"
  $bin = Get-FrpcPath

  if ((Test-Path $bin) -and $current -eq $version) {
    Ok "frpc 已是最新版：$version"
    return
  }

  # 获取平台信息
  $p = Get-PlatformInfo
  $ext = if ($p.Os -eq "windows") { "zip" } else { "tar" }
  $targetFile = "mefrpc_$($p.Os)_$($p.Arch)_$version.$ext"

  Info "目标文件：$targetFile"

  # 从 Alist 获取文件列表
  $files = Get-AlistFileList $version
  if (-not $files) {
    Err "无法获取文件列表"

    Write-Host ""
    Write-Host "============== 手动下载步骤 ==============" -ForegroundColor Yellow
    Write-Host "请在浏览器中打开以下链接下载：" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  https://drive.mcsl.com.cn/ME-Frp/Local/MEFrp-Core/$version/$targetFile" -ForegroundColor White
    Write-Host ""
    Write-Host "下载后操作：" -ForegroundColor Yellow
    Write-Host "  1. 解压下载的文件" -ForegroundColor Yellow
    Write-Host "  2. 找到 frpc.exe 或 mefrpc.exe" -ForegroundColor Yellow
    Write-Host "  3. 将文件复制到：$bin" -ForegroundColor Yellow
    Write-Host "  4. 重新运行启动器" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow

    if (Test-Path $bin) {
      Write-Host ""
      Write-Host "检测到已存在 frpc，是否继续使用？(y/n) " -ForegroundColor Green -NoNewline
      $continue = Read-Host
      if ($continue -eq 'y' -or $continue -eq 'Y' -or $continue -eq '') {
        Warn "使用现有的 frpc：$bin"
        return
      }
    }

    exit 1
  }

  # 查找目标文件
  $targetFileInfo = $files | Where-Object { $_.Name -eq $targetFile } | Select-Object -First 1

  if (-not $targetFileInfo) {
    Warn "未找到目标文件：$targetFile"
    Warn "可用的文件："
    foreach ($f in $files) {
      Write-Host "  - $($f.Name)" -ForegroundColor Gray
    }
    exit 1
  }

  $tmp = Join-Path $DataDir $targetFile
  $extract = Join-Path $DataDir "frp_extract"

  Info "正在下载 frpc：$targetFile"

  # 模拟浏览器下载
  if (-not (Download-FrpcFile $version $targetFile $tmp)) {
    Err "下载失败"

    Write-Host ""
    Write-Host "============== 手动下载步骤 ==============" -ForegroundColor Yellow
    Write-Host "请在浏览器中打开以下链接下载：" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  https://drive.mcsl.com.cn/d/ME-Frp/Local/MEFrp-Core/$version/$targetFile" -ForegroundColor White
    Write-Host ""
    Write-Host "下载后操作：" -ForegroundColor Yellow
    Write-Host "  1. 解压下载的文件" -ForegroundColor Yellow
    Write-Host "  2. 找到 frpc.exe 或 mefrpc.exe" -ForegroundColor Yellow
    Write-Host "  3. 将文件复制到：$bin" -ForegroundColor Yellow
    Write-Host "  4. 重新运行启动器" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow

    if (Test-Path $bin) {
      Write-Host ""
      Write-Host "检测到已存在 frpc，是否继续使用？(y/n) " -ForegroundColor Green -NoNewline
      $continue = Read-Host
      if ($continue -eq 'y' -or $continue -eq 'Y' -or $continue -eq '') {
        Warn "使用现有的 frpc：$bin"
        return
      }
    }

    exit 1
  }

  if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
  New-Item -ItemType Directory -Force -Path $extract | Out-Null

  Info "正在解压..."
  if ($targetFile.EndsWith(".zip")) {
    try {
      Expand-Archive -Path $tmp -DestinationPath $extract -Force
    } catch {
      Err "解压失败：$($_.Exception.Message)"
      exit 1
    }
  } else {
    # .tar 文件
    try {
      tar -xf $tmp -C $extract
    } catch {
      Err "解压失败：$($_.Exception.Message)"
      Err "请确保系统已安装 tar 命令"
      exit 1
    }
  }

  $found = Get-ChildItem -Path $extract -Recurse -File |
    Where-Object { $_.Name -match "^(mefrpc|frpc)(\.exe)?$" } |
    Select-Object -First 1

  if (-not $found) {
    Err "压缩包内未找到 frpc 可执行文件"
    Err "请检查下载的文件：$tmp"
    exit 1
  }

  Copy-Item $found.FullName $bin -Force
  Remove-Item -Force $tmp -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue
  Set-State "frp_version" $version
  Ok "frpc 已安装：$version"
}

# ============================================================
# 隧道操作
# ============================================================
function Fetch-Proxies {
  $resp = Invoke-MefrpGet "/auth/proxy/list"
  if ($resp.data.proxies) { return @($resp.data.proxies) }
  if ($resp.data.list) { return @($resp.data.list) }
  return @()
}

function Select-Proxy {
  Info "正在获取隧道列表..."
  $proxies = Fetch-Proxies
  if (-not $proxies -or $proxies.Count -eq 0) {
    Err "未找到隧道"
    exit 1
  }

  Write-Host ""
  Write-Host "================ 隧道列表 ================"
  for ($i = 0; $i -lt $proxies.Count; $i++) {
    $p = $proxies[$i]
    $pid = if ($p.proxyId) { $p.proxyId } else { $p.id }
    $name = if ($p.proxyName) { $p.proxyName } elseif ($p.name) { $p.name } else { "" }
    $type = if ($p.proxyType) { $p.proxyType } elseif ($p.type) { $p.type } else { "" }
    $node = if ($p.nodeId) { $p.nodeId } else { "" }
    $port = if ($p.remotePort) { $p.remotePort } elseif ($p.remote_port) { $p.remote_port } else { "" }
    $status = if ($null -ne $p.isOnline) { "online=$($p.isOnline)" } elseif ($p.status) { $p.status } else { "" }

    $num = $i + 1
    Write-Host ("{0,2}) [id:{1}] {2,-24} [{3}] node:{4} port:{5} {6}" -f $num, $pid, $name, $type, $node, $port, $status)
  }
  Write-Host "=========================================="

  while ($true) {
    $c = Read-Host "选择隧道编号"
    if ($c -match "^\d+$" -and [int]$c -ge 1 -and [int]$c -le $proxies.Count) {
      return $proxies[[int]$c - 1]
    }
    Warn "输入无效，请重试"
  }
}

function Save-Config([int]$proxyId) {
  $resp = Invoke-MefrpPost "/auth/proxy/config" @{ proxyId = $proxyId; format = "toml" }
  if ($resp.code -ne 200 -or -not $resp.data.config) {
    Err "获取配置失败：$($resp.message)"
    exit 1
  }

  $cfg = Join-Path $DataDir ("proxy_{0}.toml" -f $proxyId)
  [System.IO.File]::WriteAllText($cfg, $resp.data.config, (New-Object System.Text.UTF8Encoding($false)))
  Set-State "last_config" $cfg
  return $cfg
}

function Start-Proxy($proxy) {
  $proxyId = if ($proxy.proxyId) { [int]$proxy.proxyId } else { [int]$proxy.id }
  $name = if ($proxy.proxyName) { $proxy.proxyName } else { [string]$proxyId }

  Info "正在获取隧道 [$name] 配置..."
  $cfg = Save-Config $proxyId
  $bin = Get-FrpcPath
  if (-not (Test-Path $bin)) { Install-Frpc }

  Set-State "last_proxy_id" $proxyId
  Set-State "last_proxy_name" $name

  Ok "启动隧道：$name"
  Write-Host "执行：$bin -c $cfg"
  Write-Host "------------------------------------------"
  & $bin -c $cfg
}

# ============================================================
# 主程序
# ============================================================
function Main {
  Initialize-State
  Ensure-Token
  Install-Frpc
  $proxy = Select-Proxy
  Start-Proxy $proxy
}

Main