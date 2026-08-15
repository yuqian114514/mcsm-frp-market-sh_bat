# !/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import json
import requests
from pathlib import Path
import time
import getpass
import argparse

# 配置
API_BASE = "https://api.mefrp.com/api"
DRIVE_BASE = "https://drive.mcsl.com.cn"
ALIST_API_BASE = "https://drive.mcsl.com.cn/api"
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:153.0) Gecko/20100101 Firefox/153.0"
ORIGIN = "https://www.mefrp.com"
REFERER = "https://www.mefrp.com/"

# 当前脚本所在目录
SCRIPT_DIR = Path(__file__).parent.absolute()
STATE_FILE = SCRIPT_DIR / "mefrp_state.json"

# 全局调试标志和会话
DEBUG = False
SESSION = None


def debug_print(msg):
    """调试输出"""
    if DEBUG:
        print(f"[DEBUG] {msg}")


def get_session():
    """获取全局 Session"""
    global SESSION
    if SESSION is None:
        SESSION = requests.Session()
        SESSION.headers.update({
            "User-Agent": USER_AGENT,
            "Accept-Language": "zh-CN,zh;q=0.9,zh-TW;q=0.8,zh-HK;q=0.7,en-US;q=0.6,en;q=0.5",
            "Accept-Encoding": "gzip, deflate, br, zstd",
        })
    return SESSION


def load_state():
    """加载持久化状态"""
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            print(f"[!] 加载状态文件失败：{e}")
    return {}


def save_state(state):
    """保存持久化状态"""
    try:
        with open(STATE_FILE, 'w', encoding='utf-8') as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
    except Exception as e:
        print(f"[!] 保存状态文件失败：{e}")


def login_with_password(username, password, captcha_token):
    """使用用户名密码登录"""
    print("[*] 正在登录...")

    try:
        session = get_session()

        login_url = f"{API_BASE}/public/login"
        login_data = {
            "username": username,
            "password": password,
            "captchaToken": captcha_token
        }

        debug_print(f"登录 URL: {login_url}")

        response = session.post(
            login_url,
            json=login_data,
            headers={
                "Accept": "application/json, text/plain, */*",
                "Origin": ORIGIN,
                "Referer": REFERER,
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "same-site",
            },
            timeout=30
        )
        response.raise_for_status()
        result = response.json()

        debug_print(f"登录响应: {json.dumps(result, ensure_ascii=False, indent=2)[:500]}")

        if result.get("code") == 200:
            token = None

            if result.get("data"):
                token = result["data"].get("token") or result["data"].get("accessToken")

            if not token:
                cookies = response.cookies
                if "token" in cookies:
                    token = cookies["token"]

            if token:
                print("[+] 登录成功")
                return token
            else:
                print("[!] 登录成功但无法获取 Token")
                return None
        else:
            print(f"[x] 登录失败：{result.get('message', '未知错误')}")
            return None

    except Exception as e:
        print(f"[x] 登录异常：{e}")
        if DEBUG:
            import traceback
            traceback.print_exc()
        return None


def verify_token(token):
    """验证 Token 是否有效"""
    try:
        session = get_session()
        debug_print(f"验证 Token: {token[:20]}...")

        response = session.get(
            f"{API_BASE}/auth/proxy/list",
            headers={
                "Accept": "application/json, text/plain, */*",
                "Authorization": f"Bearer {token}",
                "Origin": ORIGIN,
                "Referer": REFERER,
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "same-site",
            },
            timeout=30
        )
        response.raise_for_status()
        result = response.json()
        debug_print(f"验证响应: {json.dumps(result, ensure_ascii=False)[:200]}")
        return result.get("code") == 200
    except Exception as e:
        debug_print(f"Token 验证失败: {e}")
        return False


def ensure_login():
    """确保已登录"""
    state = load_state()
    token = state.get("token")

    if token:
        print("[*] 检查现有 Token...")
        if verify_token(token):
            print("[+] Token 有效")
            return token
        else:
            print("[!] Token 已过期")

    print("")
    print("=" * 60)
    print("  需要登录 MEFrp 账户")
    print("=" * 60)
    print("")
    print("登录方式：")
    print("  1) 用户名密码登录（需要人机验证）")
    print("  2) 手动输入 Token")
    print("")

    choice = input("请选择登录方式 [1]: ").strip()
    if not choice:
        choice = "1"

    if choice == "2":
        print("")
        print("从此处获取 Token：https://www.mefrp.com")
        token = input("请输入 Token: ").strip()

        if not token:
            print("[x] Token 不能为空")
            sys.exit(1)

        if not verify_token(token):
            print("[x] Token 无效或已过期")
            sys.exit(1)

        print("[+] Token 验证成功")

    else:
        print("")
        username = input("用户名: ").strip()
        password = getpass.getpass("密码: ")

        print("")
        print("[*] 请完成人机验证")
        print("[*] 访问：https://www.mefrp.com/3rdparty/captcha?client=mcsmFRPTemplateMefrpDownloader")
        print("[*] 完成验证后，将显示的验证码粘贴到下方")
        print("")
        captcha_token = input("验证码 Token: ").strip()

        if not captcha_token:
            print("[x] 验证码不能为空")
            sys.exit(1)

        try:
            import base64
            decoded = base64.b64decode(captcha_token).decode('utf-8')
            if '||' in decoded:
                captcha_token = decoded.split('||')[0]
                debug_print(f"Base64 解码后的验证码: {captcha_token}")
        except:
            debug_print("验证码不是 Base64 格式，使用原值")
            pass

        token = login_with_password(username, password, captcha_token)

        if not token:
            print("[x] 登录失败")
            sys.exit(1)

    state["token"] = token
    save_state(state)
    print("[+] Token 已保存")

    return token


def get_latest_version(token):
    """从 API 获取最新版本号"""
    print("[*] 正在获取最新版本信息...")
    
    session = get_session()
    
    # 通过 /auth/products 获取版本号
    endpoint = "/auth/products"
    
    try:
        url = API_BASE + endpoint
        debug_print(f"获取产品信息：{url}")
        
        response = session.get(
            url,
            headers={
                "Accept": "application/json, text/plain, */*",
                "Authorization": f"Bearer {token}",
                "Origin": ORIGIN,
                "Referer": REFERER,
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "same-site",
            },
            timeout=30
        )
        response.raise_for_status()
        
        html = response.text
        debug_print(f"返回内容（前500字符）：{html[:500]}")
        
        import re
        match = re.search(r'/ME-Frp/Local/MEFrp-Core/([^/"]+)/', html)
        if match:
            version = match.group(1)
            print(f"[+] 找到最新版本：{version}")
            return version
        
        try:
            data = json.loads(html)
            debug_print(f"JSON 结构：{json.dumps(data, indent=2, ensure_ascii=False)[:500]}")
            
            if isinstance(data, dict) and "data" in data:
                if isinstance(data["data"], dict):
                    version = data["data"].get("version") or data["data"].get("tag")
                    if version:
                        print(f"[+] 找到最新版本：{version}")
                        return version
                elif isinstance(data["data"], list):
                    # 可能是产品列表，遍历查找
                    for item in data["data"]:
                        if isinstance(item, dict):
                            # 查找包含版本信息的字段
                            for key in ["version", "tag", "name"]:
                                if key in item:
                                    val = str(item[key])
                                    # 检查是否是版本号格式
                                    if re.match(r'\d+\.\d+\.\d+_\d+_[a-f0-9]+', val):
                                        print(f"[+] 找到最新版本：{val}")
                                        return val
        except json.JSONDecodeError:
            pass
            
    except Exception as e:
        print(f"[!] 获取版本失败：{e}")
        if DEBUG:
            import traceback
            traceback.print_exc()
    
    print("[!] 无法自动获取版本号")
    version = input("请手动输入 MEFrp 版本号（如 0.67.1_20260626_af59eefd）: ").strip()
    return version


def get_file_list_from_alist(version):
    """获取文件列表（不访问页面）"""
    print(f"[*] 正在获取版本 {version} 的文件列表...")
    
    session = get_session()
    
    try:
        path = f"/ME-Frp/Local/MEFrp-Core/{version}"
        url = f"{ALIST_API_BASE}/fs/list"
        params = {"path": path}
        
        debug_print(f"获取文件列表: {url}?path={path}")
        
        response = session.get(
            url,
            params=params,
            headers={
                "Accept": "*/*",
                "Accept-Encoding": "gzip, deflate, br, zstd",
                "Origin": "https://www.mefrp.com",
                "Referer": "https://www.mefrp.com/",
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "cross-site",
                "Priority": "u=0",
            },
            timeout=30
        )
        
        debug_print(f"响应状态码: {response.status_code}")
        debug_print(f"响应头: {dict(response.headers)}")
        debug_print(f"响应内容长度: {len(response.content)} 字节")
        
        response.raise_for_status()
        
        # 检查响应是否完整
        content_length = response.headers.get('content-length')
        if content_length:
            expected_length = int(content_length)
            actual_length = len(response.content)
            if expected_length != actual_length:
                print(f"[!] 响应不完整：期望 {expected_length} 字节，实际 {actual_length} 字节")
                debug_print(f"响应内容（实际接收）: {response.text[:1000]}")
                return []
        
        # 尝试解析 JSON
        try:
            result = response.json()
        except json.JSONDecodeError as e:
            print(f"[!] JSON 解析失败：{e}")
            debug_print(f"响应内容: {response.text[:1000]}")
            return []
        
        debug_print(f"Alist 响应: {json.dumps(result, ensure_ascii=False, indent=2)[:1000]}")
        
        if result.get("code") == 200:
            data = result.get("data", {})
            files = data.get("content", [])
            
            debug_print(f"data 字段: {json.dumps(data, ensure_ascii=False, indent=2)[:500]}")
            debug_print(f"files 数量: {len(files)}")
            
            if not files:
                print("[!] 未找到文件列表")
                print(f"[DEBUG] 完整响应: {json.dumps(result, ensure_ascii=False, indent=2)}")
                return []
            
            file_list = []
            for file in files:
                name = file.get("name", "")
                debug_print(f"处理文件: {name}")
                
                # 匹配所有 mefrpc 文件：.zip, .tar.gz, .tar
                if name.startswith("mefrpc_") and (name.endswith(".zip") or name.endswith(".tar.gz") or name.endswith(".tar")):
                    file_list.append({
                        "name": name,
                        "size": file.get("size", 0),
                        "modified": file.get("modified", "")
                    })
            
            if len(file_list) == 0:
                print("[!] 未找到匹配的 mefrpc 文件")
                print(f"[*] 目录下所有文件：")
                for file in files:
                    print(f"    - {file.get('name', 'unknown')}")
                return []
            
            print(f"[+] 找到 {len(file_list)} 个文件")
            for f in file_list:
                size_mb = f['size'] / (1024 * 1024)
                print(f"    - {f['name']} ({size_mb:.2f} MB)")
            
            return file_list
        else:
            error_msg = result.get('message', '未知错误')
            error_code = result.get('code', 'N/A')
            print(f"[!] Alist API 返回错误 (code: {error_code}): {error_msg}")
            debug_print(f"完整响应: {json.dumps(result, ensure_ascii=False, indent=2)}")
            return []
            
    except requests.exceptions.Timeout:
        print(f"[!] 请求超时")
        if DEBUG:
            import traceback
            traceback.print_exc()
        return []
    except requests.exceptions.ConnectionError as e:
        print(f"[!] 连接错误: {e}")
        if DEBUG:
            import traceback
            traceback.print_exc()
        return []
    except Exception as e:
        print(f"[!] 获取文件列表失败：{e}")
        if DEBUG:
            import traceback
            traceback.print_exc()
        return []


def visit_file_page(version, filename):
    """访问文件页面（模拟用户浏览到文件）"""
    session = get_session()
    
    file_page_url = f"https://drive.mcsl.com.cn/ME-Frp/Local/MEFrp-Core/{version}/{filename}"
    
    try:
        debug_print(f"访问文件页面: {file_page_url}")
        
        # 模拟用户浏览到文件页面
        session.get(
            file_page_url,
            headers={
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                "Referer": f"https://drive.mcsl.com.cn/ME-Frp/Local/MEFrp-Core/{version}",
                "Sec-Fetch-Dest": "document",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Site": "same-origin",
                "Upgrade-Insecure-Requests": "1",
            },
            timeout=15
        )
        
        debug_print("已访问文件页面")
        time.sleep(1.5)  # 模拟用户查看文件信息的时间
        print("[+] 已访问文件页面")
        
    except Exception as e:
        debug_print(f"访问文件页面失败: {e}")


def download_file_like_browser(version, filename, output_path):
    """模拟浏览器点击下载"""
    session = get_session()
    
    # 构建下载 URL
    file_path = f"/ME-Frp/Local/MEFrp-Core/{version}/{filename}"
    download_url = f"{DRIVE_BASE}/d{file_path}"
    
    print(f"[*] 下载链接: {download_url}")

    retries = 3
    for attempt in range(1, retries + 1):
        try:
            if attempt > 1:
                print(f"[*] 尝试下载（第 {attempt}/{retries} 次）...")

            debug_print(f"开始下载: {download_url}")

            # 模拟点击下载链接
            response = session.get(
                download_url,
                headers={
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                    "Referer": f"https://drive.mcsl.com.cn/ME-Frp/Local/MEFrp-Core/{version}/{filename}",
                    "Sec-Fetch-Dest": "document",
                    "Sec-Fetch-Mode": "navigate",
                    "Sec-Fetch-Site": "same-origin",
                    "Upgrade-Insecure-Requests": "1",
                },
                stream=True,
                timeout=120,
                allow_redirects=True
            )

            debug_print(f"响应状态码: {response.status_code}")
            debug_print(f"响应头: {dict(response.headers)}")

            if response.status_code in [418, 500, 502, 503]:
                debug_print(f"错误响应内容（前500字符）: {response.text[:500]}")

            response.raise_for_status()

            total_size = int(response.headers.get('content-length', 0))
            debug_print(f"文件大小: {total_size} 字节")

            output_path.parent.mkdir(parents=True, exist_ok=True)

            with open(output_path, 'wb') as f:
                if total_size == 0:
                    f.write(response.content)
                else:
                    downloaded = 0
                    chunk_size = 8192
                    for chunk in response.iter_content(chunk_size=chunk_size):
                        if chunk:
                            f.write(chunk)
                            downloaded += len(chunk)
                            percent = (downloaded / total_size) * 100
                            mb_downloaded = downloaded / (1024 * 1024)
                            mb_total = total_size / (1024 * 1024)
                            print(f"\r[*] 下载进度: {percent:.1f}% ({mb_downloaded:.2f}/{mb_total:.2f} MB)", end='', flush=True)
                    print()

            file_size = os.path.getsize(output_path)
            if file_size < 100 * 1024:
                print(f"[!] 下载的文件太小（{file_size} 字节），可能是错误页面")
                if DEBUG:
                    with open(output_path, 'rb') as f:
                        content = f.read(500)
                        try:
                            debug_print(f"文件内容（前500字节）: {content.decode('utf-8', errors='ignore')}")
                        except:
                            debug_print(f"文件内容（二进制）: {content[:100]}")
                os.remove(output_path)
                continue

            print(f"[+] 下载成功！文件大小：{file_size / (1024*1024):.2f} MB")
            return True

        except Exception as e:
            print(f"[!] 下载失败：{e}")
            if DEBUG:
                import traceback
                traceback.print_exc()

        if os.path.exists(output_path):
            os.remove(output_path)

        if attempt < retries:
            wait_time = 3 + (attempt * 2)
            print(f"[*] 等待 {wait_time} 秒后重试...")
            time.sleep(wait_time)

    return False


def main():
    global DEBUG

    parser = argparse.ArgumentParser(description='MEFrp 全平台自动下载工具')
    parser.add_argument('-d', '--debug', action='store_true', help='启用调试模式')
    args = parser.parse_args()

    DEBUG = args.debug

    if DEBUG:
        print("[DEBUG] 调试模式已启用")

    print("")
    print("=" * 60)
    print("  MEFrp 全平台自动下载工具")
    print("  Author: YuQian")
    print("  运行环境: Linux")
    print("=" * 60)
    print("")

    # 1. 登录获取 Token
    token = ensure_login()
    
    print("")
    
    # 2. 通过 /auth/products 获取版本号
    version = get_latest_version(token)
    if not version:
        print("[x] 无法获取版本号，退出")
        sys.exit(1)
    
    print("")
    
    # 3. 获取文件列表
    file_list = get_file_list_from_alist(version)
    if not file_list:
        print("[x] 无法获取文件列表，退出")
        sys.exit(1)

    print("")
    print(f"[*] 将下载以下文件：")
    for f in file_list:
        size_mb = f['size'] / (1024 * 1024)
        print(f"    - {f['name']} ({size_mb:.2f} MB)")

    print("")
    choice = input("[?] 确认开始下载？(y/n) [y]: ").strip().lower()
    if choice and choice != 'y':
        print("[*] 取消下载")
        sys.exit(0)

    total = len(file_list)
    success_count = 0
    failed = []

    start_time = time.time()

    for idx, file_info in enumerate(file_list):
        filename = file_info['name']

        relative_path = f"ME-Frp/Local/MEFrp-Core/{version}/{filename}"
        output_path = SCRIPT_DIR / relative_path

        print("")
        print("=" * 60)
        print(f"[{idx+1}/{total}] {filename}")
        print("=" * 60)
        
        if output_path.exists():
            file_size = os.path.getsize(output_path)
            if file_size > 100 * 1024:
                print(f"[!] 文件已存在（{file_size / (1024*1024):.2f} MB），跳过下载")
                success_count += 1
                continue
            else:
                print(f"[!] 文件已存在但太小，重新下载")
                os.remove(output_path)
        
        # 4. 访问文件页面（模拟用户浏览到文件）
        visit_file_page(version, filename)
        
        # 5. 逐个下载（模拟点击下载按钮）
        if download_file_like_browser(version, filename, output_path):
            success_count += 1
        else:
            failed.append(filename)

        # 模拟用户在文件间切换的间隔
        if idx < len(file_list) - 1:
            wait = 3
            print(f"[*] 等待 {wait} 秒后下载下一个文件...")
            time.sleep(wait)

    end_time = time.time()
    elapsed = end_time - start_time

    print("")
    print("=" * 60)
    print("  下载完成")
    print("=" * 60)
    print(f"[*] 总计：{total} 个文件")
    print(f"[+] 成功：{success_count} 个")
    print(f"[x] 失败：{len(failed)} 个")
    print(f"[*] 耗时：{elapsed:.1f} 秒")
    
    if failed:
        print("")
        print("[!] 失败的文件：")
        for f in failed:
            print(f"    - {f}")
    
    print("")
    print(f"[*] 文件保存在：{SCRIPT_DIR / 'ME-Frp' / 'Local' / 'MEFrp-Core' / version}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[!] 用户中断")
        sys.exit(1)
    except Exception as e:
        print(f"\n[x] 发生错误：{e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)