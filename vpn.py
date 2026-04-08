#! /usr/local/bin/python
#-*- coding:utf-8 -*-

import pyotp
import subprocess
import sys
import os
import time

def notify(title, message):
    subprocess.run([
        "osascript", "-e",
        f'display notification "{message}" with title "{title}"'
    ])

def is_running():
    try:
        result = subprocess.run(["pgrep", "-x", "openconnect"], capture_output=True, text=True)
        return result.returncode == 0
    except Exception:
        return False

def start():
    if is_running():
        notify("VPN", "已经在运行中，请勿重复启动")
        sys.exit(0)

    totp = pyotp.TOTP("EXAMPLEBASE32SECRETPLACEHOLDER34").now()
    password = "ExamplePass2021" + totp

    cmd = [
        "sudo", "-n", "/opt/homebrew/bin/openconnect",
        "--script", "/opt/homebrew/Cellar/openconnect/9.12_1/.bottle/etc/vpnc/vpnc-script",
        "--user", "first.last",
        "--passwd-on-stdin",
        "--servercert", "pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "vpn.example.com"
    ]

    try:
        with open(os.devnull, 'wb') as devnull:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=devnull,
                stderr=devnull,
                preexec_fn=os.setpgrp
            )
            proc.stdin.write(password.encode() + b"\n")
            proc.stdin.flush()
            proc.stdin.close()

        time.sleep(2)
        if is_running():
            notify("VPN", "连接成功")
        else:
            notify("VPN", "启动失败，请检查网络或配置")

    except Exception as e:
        notify("VPN", f"启动异常: {e}")

if __name__ == "__main__":
    start()


# 1. 安装步骤
# /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# brew install openconnect
# pip3 install pyotp
# where openconnect

# def start():
#     totp = pyotp.TOTP("运维给得OTP访问码").now()
#     password = "自己固定的密码" + totp
#     cmd = [
#            "sudo", "需要找到本机安装位置",
#            "--script", "/opt/homebrew/Cellar/openconnect/9.12_1/.bottle/etc/vpnc/vpnc-script", 替换这个是为了不让他修改本机dns
#            "--user", "用户姓名",
#            "--passwd-on-stdin",
#            "--servercert", "运维给的", 
#            "vpn.example.com"
#            ]
#     subprocess.run(cmd, input=password.encode(), check=True)
# start()


# 2. 无需输入密码
# sudo visudo
# 电脑名 ALL=(root) NOPASSWD: openconnect位置
# eg: demo ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect




