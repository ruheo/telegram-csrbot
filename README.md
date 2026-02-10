## Disclaimer

This project is intended for legitimate customer support and communication purposes only.

- Users must initiate conversations voluntarily.
- The bot does not send unsolicited messages.
- All data handling must comply with local laws and Telegram Terms of Service.
- The author is not responsible for misuse of this software.



# 🚀 TG多客服机器人部署指南

## 提示:所有内容都存储于你本地.

### 方法 1: 交互式部署

```bash
curl -fsSL https://raw.githubusercontent.com/ruheo/telegram-csrbot/main/deploy.sh | sudo bash
```

脚本会引导你输入：
1. Bot Token
2. 管理员 ID
3. 提示:所有内容都存储于你本地.
---

### 方法 2: 一键部署

```bash
curl -fsSL https://raw.githubusercontent.com/ruheo/telegram-csrbot/main/deploy.sh | ( [ $(id -u) -eq 0 ] && bash -s -- "YOUR_BOT_TOKEN" "YOUR_USER_ID1,YOUR_USER_ID2" || sudo bash -s -- "YOUR_BOT_TOKEN" "YOUR_USER_ID1,YOUR_USER_ID2" )
```

**示例**：
```bash
curl -fsSL https://raw.githubusercontent.com/ruheo/telegram-csrbot/main/deploy.sh | ( [ $(id -u) -eq 0 ] && bash -s -- "1234567890:ABCdefGHIjklMNOpqrsTUVwxyz" "123456789,987654321" || sudo bash -s -- "1234567890:ABCdefGHIjklMNOpqrsTUVwxyz" "123456789,987654321" )
```

---
### 卸载已包含在安装脚本中,卸载命令:

```bash
uninstall_tgbot
```
---

## 🔑 获取必要信息

### 1. 获取 Bot Token

1. 在 Telegram 中找到 [@BotFather](https://t.me/BotFather)
2. 发送 `/newbot`
3. 按提示设置机器人名称和用户名
4. 复制收到的 Token

**Token 格式**：`1234567890:ABCdefGHIjklMNOpqrsTUVwxyz`

---

### 2. 获取管理员 ID

1. 在 Telegram 中找到 [@userinfobot](https://t.me/userinfobot)
2. 发送任意消息
3. 复制你的 `User ID`（纯数字）

**多个管理员**：用逗号分隔，**不要加空格**
- ✅ 正确：`123456789,987654321,111222333`
- ❌ 错误：`123456789, 987654321, 111222333`（有空格）

---
