"""
Zed 批量登录工具
使用 Playwright 自动化浏览器，批量用 GitHub 账号获取 Zed 凭证

用法:
  1. 准备 github_accounts.json (格式见下方)
  2. pip install playwright cryptography
  3. playwright install chromium
  4. python batch_login.py

github_accounts.json 格式:
[
  {"username": "user1", "password": "pass1"},
  {"username": "user2", "password": "pass2"}
]

也支持用 GitHub session cookie:
[
  {"username": "user1", "cookie": "user_session=xxxx"}
]

结果写入 accounts.json (zed2api 格式)
"""
import json
import base64
import os
import sys
import time
import socket
import threading
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend


def generate_keypair():
    private_key = rsa.generate_private_key(
        public_exponent=65537, key_size=2048, backend=default_backend()
    )
    public_der = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.PKCS1,
    )
    pub_b64 = base64.urlsafe_b64encode(public_der).decode().rstrip("=")
    return private_key, pub_b64


def decrypt_token(private_key, encrypted_b64: str) -> str:
    pad_needed = (4 - len(encrypted_b64) % 4) % 4
    encrypted_b64 += "=" * pad_needed
    encrypted = base64.urlsafe_b64decode(encrypted_b64)
    try:
        plaintext = private_key.decrypt(
            encrypted,
            padding.OAEP(
                mgf=padding.MGF1(algorithm=hashes.SHA256()),
                algorithm=hashes.SHA256(),
                label=None,
            ),
        )
    except Exception:
        plaintext = private_key.decrypt(encrypted, padding.PKCS1v15())
    return plaintext.decode("utf-8")


class CallbackHandler(BaseHTTPRequestHandler):
    credentials = None
    private_key = None

    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if "user_id" in params and "access_token" in params:
            user_id = params["user_id"][0]
            enc_token = params["access_token"][0]
            try:
                token_json = decrypt_token(self.private_key, enc_token)
                CallbackHandler.credentials = {
                    "user_id": user_id,
                    "access_token": json.loads(token_json),
                }
                self.send_response(302)
                self.send_header("Location", "https://zed.dev/native_app_signin_succeeded")
                self.end_headers()
            except Exception as e:
                print(f"    [!] 解密失败: {e}")
                self.send_response(500)
                self.end_headers()
        else:
            self.send_response(400)
            self.end_headers()

    def log_message(self, *args):
        pass


def get_free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_callback_server(private_key, port):
    CallbackHandler.private_key = private_key
    CallbackHandler.credentials = None
    server = HTTPServer(("127.0.0.1", port), CallbackHandler)
    server.timeout = 120
    return server


def login_one_account(pw_browser, account: dict, index: int, total: int) -> dict | None:
    """用 Playwright 自动化单个账号的登录流程"""
    username = account.get("username", "")
    cookie = account.get("cookie", "")
    password = account.get("password", "")
    name = account.get("name", username)

    print(f"\n[{index+1}/{total}] 登录 {username}...")

    # 生成密钥对 + 启动回调服务器
    private_key, pub_b64 = generate_keypair()
    port = get_free_port()
    server = start_callback_server(private_key, port)

    login_url = (
        f"https://zed.dev/native_app_signin"
        f"?native_app_port={port}"
        f"&native_app_public_key={urllib.parse.quote(pub_b64)}"
    )

    context = pw_browser.new_context()
    try:
        # 如果提供了 GitHub session cookie，直接注入
        if cookie:
            # 解析 cookie 字符串，支持 "user_session=xxx" 或 "xxx"
            if "=" in cookie:
                cookie_name, cookie_value = cookie.split("=", 1)
            else:
                cookie_name, cookie_value = "user_session", cookie
            context.add_cookies([{
                "name": cookie_name,
                "value": cookie_value,
                "domain": ".github.com",
                "path": "/",
                "httpOnly": True,
                "secure": True,
            }])

        page = context.new_page()
        page.set_default_timeout(60000)

        # 访问 Zed 登录页
        print(f"    打开 zed.dev 登录页...")
        page.goto(login_url, wait_until="networkidle")
        time.sleep(2)

        current_url = page.url
        print(f"    当前页面: {current_url[:80]}...")

        # 如果跳转到了 GitHub 登录页，填写用户名密码
        if "github.com/login" in current_url:
            if not password:
                print(f"    [!] 需要密码但未提供，跳过")
                return None

            print(f"    填写 GitHub 登录...")
            page.fill("#login_field", username)
            page.fill("#password", password)
            page.click('input[type="submit"]')
            page.wait_for_load_state("networkidle")
            time.sleep(2)

            # 检查是否需要 2FA
            current_url = page.url
            if "two-factor" in current_url or "sessions/two-factor" in current_url:
                print(f"    [!] 需要 2FA，跳过 (暂不支持自动 2FA)")
                return None

            # 检查登录是否失败
            if "github.com/login" in page.url:
                print(f"    [!] GitHub 登录失败 (密码错误?)")
                return None

        # 如果到了 GitHub OAuth 授权页，点击授权
        current_url = page.url
        if "github.com/login/oauth/authorize" in current_url:
            print(f"    点击 GitHub 授权...")
            try:
                # 找到授权按钮并点击
                authorize_btn = page.locator('button[name="authorize"]')
                if authorize_btn.count() > 0:
                    authorize_btn.click()
                else:
                    # 有时候是 input submit
                    page.click('button:has-text("Authorize")')
                page.wait_for_load_state("networkidle")
                time.sleep(2)
            except Exception:
                # 可能已经授权过，自动跳转了
                pass

        # 等待回调
        print(f"    等待 Zed 回调...")
        server.handle_request()

        if CallbackHandler.credentials:
            creds = CallbackHandler.credentials
            print(f"    OK user_id={creds['user_id']}")
            return {
                "name": name or f"account_{creds['user_id']}",
                "user_id": creds["user_id"],
                "credential": creds["access_token"],
            }
        else:
            print(f"    [!] 未收到回调")
            return None

    except Exception as e:
        print(f"    [!] 异常: {e}")
        return None
    finally:
        context.close()
        server.server_close()


def save_accounts(results: list, output_path: str):
    """保存到 accounts.json"""
    config = {"accounts": {}}
    if os.path.exists(output_path):
        with open(output_path, "r", encoding="utf-8") as f:
            config = json.load(f)

    for r in results:
        config["accounts"][r["name"]] = {
            "user_id": r["user_id"],
            "credential": r["credential"],
        }

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


def main():
    input_file = sys.argv[1] if len(sys.argv) > 1 else "github_accounts.json"
    output_file = sys.argv[2] if len(sys.argv) > 2 else "accounts.json"

    if not os.path.exists(input_file):
        print(f"找不到 {input_file}")
        print(f"\n创建示例文件...")
        example = [
            {"username": "github_user1", "password": "password1", "name": "account1"},
            {"username": "github_user2", "cookie": "user_session=abc123", "name": "account2"},
        ]
        with open(input_file, "w") as f:
            json.dump(example, f, indent=2)
        print(f"已创建 {input_file}，请填写账号信息后重新运行")
        return

    with open(input_file, "r", encoding="utf-8") as f:
        accounts_list = json.load(f)

    print(f"=== Zed 批量登录 ===")
    print(f"账号数: {len(accounts_list)}")
    print(f"输出: {output_file}")

    from playwright.sync_api import sync_playwright

    results = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)  # 有头模式，方便调试
        try:
            for i, acc in enumerate(accounts_list):
                result = login_one_account(browser, acc, i, len(accounts_list))
                if result:
                    results.append(result)
                    # 每成功一个就保存，防止中途失败丢数据
                    save_accounts(results, output_file)
                time.sleep(1)
        finally:
            browser.close()

    print(f"\n=== 完成 ===")
    print(f"成功: {len(results)}/{len(accounts_list)}")
    if results:
        print(f"已保存到 {output_file}")


if __name__ == "__main__":
    main()
