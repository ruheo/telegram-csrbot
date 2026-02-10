#!/bin/bash

# =================================================================
# 🤖 Telegram 客服机器人 - 部署脚本 v6.1 (视觉增强版)
# =================================================================

# 开启严格模式 (输入环节临时关闭)
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BOT_USERNAME="tgbot"
INSTALL_DIR="/opt/tgbot"
LOG_DIR="/var/log/tgbot"
DATA_DIR="/var/lib/tgbot"

log() { echo -e "${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

run_as_bot() {
    if [ "$EUID" -eq 0 ]; then
        if command -v sudo &>/dev/null; then
            sudo -u "$BOT_USERNAME" bash -c "$*"
        else
            su - "$BOT_USERNAME" -c "$*"
        fi
    else
        bash -c "$*"
    fi
}

# --- 1. 输入环节 (防闪退) ---
get_user_inputs() {
    set +e
    if [ $# -eq 0 ]; then
        echo -e "${YELLOW}=== 交互配置模式 ===${NC}"
        echo -ne "${CYAN}请输入 Bot Token: ${NC}"
        if [ -t 0 ]; then read -r BOT_TOKEN; else read -r BOT_TOKEN < /dev/tty; fi
        echo -ne "${CYAN}请输入管理员 ID (逗号分隔): ${NC}"
        if [ -t 0 ]; then read -r OWNER_IDS; else read -r OWNER_IDS < /dev/tty; fi
    elif [ $# -eq 2 ]; then
        BOT_TOKEN="$1"; OWNER_IDS="$2"
    else
        echo "用法: curl ... | bash -s -- <TOKEN> <IDS>"; exit 1
    fi
    set -e
    if [[ -z "$BOT_TOKEN" || -z "$OWNER_IDS" ]]; then error "Token 或 ID 不能为空"; exit 1; fi
}

# --- 2. 环境安装 ---
install_deps() {
    log "检查依赖..."
    if [ "$EUID" -eq 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y python3-full python3-pip python3-venv sqlite3 curl sudo >/dev/null 2>&1 || true
    fi
}

setup_env() {
    log "配置环境..."
    id "$BOT_USERNAME" &>/dev/null || useradd -r -s /bin/bash -d "$INSTALL_DIR" -m "$BOT_USERNAME"
    mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$DATA_DIR"
    chown -R "$BOT_USERNAME:$BOT_USERNAME" "$INSTALL_DIR" "$LOG_DIR" "$DATA_DIR"
}

setup_python() {
    log "配置 Python..."
    cd "$INSTALL_DIR"
    [ -d "venv" ] && rm -rf venv
    run_as_bot "python3 -m venv venv"
    run_as_bot "venv/bin/pip install --upgrade pip -q"
    run_as_bot "venv/bin/pip install python-telegram-bot -q"
}

# --- 3. 生成代码 ---
create_files() {
    log "生成核心文件..."
    
    cat > "$INSTALL_DIR/config.env" <<EOF
BOT_TOKEN=$BOT_TOKEN
OWNER_IDS=$OWNER_IDS
LOG_FILE=$LOG_DIR/bot.log
DB_FILE=$DATA_DIR/messages.db
EOF
    chmod 600 "$INSTALL_DIR/config.env"
    chown "$BOT_USERNAME:$BOT_USERNAME" "$INSTALL_DIR/config.env"

    cat > "$INSTALL_DIR/init_db.py" <<'EOF'
import sqlite3, sys
def init(path):
    with sqlite3.connect(path) as conn:
        conn.execute('''CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY, user_id INTEGER, username TEXT, first_name TEXT, message_text TEXT, 
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, replied_by INTEGER, replied_at DATETIME
        )''')
        conn.execute('''CREATE TABLE IF NOT EXISTS sessions (
            user_id INTEGER PRIMARY KEY, last_message_time DATETIME, assigned_admin INTEGER
        )''')
        conn.execute('CREATE INDEX IF NOT EXISTS idx_uid ON messages(user_id)')
        conn.execute('CREATE INDEX IF NOT EXISTS idx_time ON messages(timestamp)')
if __name__ == '__main__': init(sys.argv[1])
EOF
    run_as_bot "venv/bin/python init_db.py $DATA_DIR/messages.db"

    # --- 🤖 Bot 主程序 (v6.1 视觉增强版) ---
    cat > "$INSTALL_DIR/bot.py" <<'EOFBOT'
import logging
import asyncio
import os
import sqlite3
from collections import defaultdict
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ForceReply
from telegram.ext import ApplicationBuilder, CommandHandler, MessageHandler, CallbackQueryHandler, filters, ContextTypes

def load_config():
    return {
        'TOKEN': os.getenv('BOT_TOKEN'),
        'OWNER_IDS': [int(x) for x in os.getenv('OWNER_IDS').split(',')],
        'LOG_FILE': os.getenv('LOG_FILE'),
        'DB_FILE': os.getenv('DB_FILE')
    }
CONFIG = load_config()

logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(message)s', 
    level=logging.INFO,
    handlers=[logging.FileHandler(CONFIG['LOG_FILE']), logging.StreamHandler()]
)
logger = logging.getLogger(__name__)

class Database:
    def __init__(self, path): self.path = path
    def connect(self): return sqlite3.connect(self.path)
    
    def save_message(self, user_id, username, first_name, text):
        with self.connect() as conn:
            conn.execute('INSERT INTO messages (user_id, username, first_name, message_text) VALUES (?,?,?,?)', (user_id, username, first_name, text))
            
    def mark_replied(self, user_id, admin_id):
        with self.connect() as conn:
            conn.execute('UPDATE messages SET replied_by=?, replied_at=CURRENT_TIMESTAMP WHERE user_id=? AND replied_by IS NULL', (admin_id, user_id))
            
    def get_history(self, user_id):
        with self.connect() as conn:
            return conn.execute('SELECT message_text, timestamp, replied_by FROM messages WHERE user_id=? ORDER BY timestamp DESC LIMIT 5', (user_id,)).fetchall()
            
    def get_stats(self):
        with self.connect() as conn:
            today = conn.execute("SELECT COUNT(*) FROM messages WHERE date(timestamp) = date('now')").fetchone()[0]
            pending = conn.execute("SELECT COUNT(*) FROM messages WHERE replied_by IS NULL").fetchone()[0]
            users = conn.execute("SELECT COUNT(DISTINCT user_id) FROM messages").fetchone()[0]
            return today, pending, users

db = Database(CONFIG['DB_FILE'])
reply_context = {}
locks = defaultdict(asyncio.Lock)

def escape_md(text):
    if not text: return ""
    for char in ['\\', '.', '_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=', '|', '{', '}', '!']:
        text = text.replace(char, f'\\{char}')
    return text

def get_full_name(user):
    return f"{user.first_name} {user.last_name or ''}".strip()

async def notify_admins(context, text, keyboard):
    async def send(aid):
        try: await context.bot.send_message(chat_id=aid, text=text, reply_markup=keyboard, parse_mode='MarkdownV2')
        except Exception as e: logger.error(f"Notify failed: {e}")
    await asyncio.gather(*[send(aid) for aid in CONFIG['OWNER_IDS']])

async def sync_team(context, operator_id, text):
    async def send(aid):
        if aid != operator_id:
            try: await context.bot.send_message(chat_id=aid, text=text, parse_mode='MarkdownV2')
            except Exception as e: logger.error(f"Sync failed: {e}")
    await asyncio.gather(*[send(aid) for aid in CONFIG['OWNER_IDS']])

async def start_command(update: Update, context):
    if update.effective_user.id in CONFIG['OWNER_IDS']:
        help_text = (
            "👋 *管理员控制台*\n\n"
            "📚 *命令列表:*\n"
            "`/stats` \\- 查看数据统计\n"
            "`/history <id>` \\- 查询用户历史\n"
            "`/help` \\- 显示此帮助"
        )
        await update.message.reply_text(help_text, parse_mode='MarkdownV2')
    else:
        await update.message.reply_text("👋 您好，请直接留言，我们会尽快回复。")

async def stats_command(update: Update, context):
    if update.effective_user.id not in CONFIG['OWNER_IDS']: return
    try:
        today, pending, users = db.get_stats()
        text = (
            f"📊 *数据统计*\n\n"
            f"📅 今日消息: `{today}`\n"
            f"⏳ 待处理: `{pending}`\n"
            f"👥 总用户: `{users}`"
        )
        await update.message.reply_text(text, parse_mode='MarkdownV2')
    except Exception as e:
        await update.message.reply_text(f"❌ 查询失败: {e}")

async def history_command(update: Update, context):
    if update.effective_user.id not in CONFIG['OWNER_IDS']: return
    try:
        if not context.args:
            await update.message.reply_text("ℹ️ 用法: `/history 123456`", parse_mode='MarkdownV2')
            return
        
        target_id = int(context.args[0])
        history = db.get_history(target_id)
        if history:
            lines = []
            for r in history:
                stat = '✅' if r[2] else '⏳'
                time_str = escape_md(str(r[1])[5:16])
                msg_preview = escape_md(str(r[0])[:15])
                lines.append(f"{stat} `{time_str}` {msg_preview}\.\.\.")
            msg = f"📜 *用户 {target_id} 的历史*\n" + "\n".join(lines)
        else:
            msg = f"📜 *用户 {target_id}*\n无记录"
        await update.message.reply_text(msg, parse_mode='MarkdownV2')
    except ValueError:
        await update.message.reply_text("❌ ID 必须是数字")
    except Exception as e:
        await update.message.reply_text(f"❌ 错误: {e}")

async def forward_message(update: Update, context):
    user = update.effective_user
    if user.id in CONFIG['OWNER_IDS']: return
    async with locks[user.id]:
        content = update.message.text or f"[{update.message.caption or '媒体消息'}]"
        try:
            db.save_message(user.id, user.username, user.first_name, content)
            
            info_text = (
                f"📩 *[新消息]*\n"
                f"👤 名字: {escape_md(get_full_name(user))}\n"
                f"🔗 账号: {escape_md(f'@{user.username}' if user.username else '无')}\n"
                f"🆔 ID: `{user.id}`\n{'─'*15}\n{escape_md(content)}"
            )
            
            # --- 🔥 按钮视觉优化修改处 🔥 ---
            keyboard = InlineKeyboardMarkup([
                [InlineKeyboardButton("✍️ 回复", callback_data=f"reply_{user.id}"), 
                 InlineKeyboardButton("📜 历史", callback_data=f"history_{user.id}")],
                [InlineKeyboardButton("✅ 标记已处理", callback_data=f"done_{user.id}")]
            ])
            # -------------------------------

            await notify_admins(context, info_text, keyboard)
            
            if not update.message.text:
                for aid in CONFIG['OWNER_IDS']:
                    try: await update.message.forward(aid)
                    except: pass
            if update.message.text: await update.message.reply_text("✅ 已收到")
        except Exception as e:
            logger.error(f"Forward error: {e}")

async def handle_callback(update: Update, context):
    query = update.callback_query
    if query.from_user.id not in CONFIG['OWNER_IDS']: return await query.answer("无权限", show_alert=True)
    
    try:
        action, target_uid = query.data.split('_')
        target_uid = int(target_uid)
        
        if action == 'reply':
            await query.answer()
            sent = await context.bot.send_message(query.from_user.id, f"✍️ *请回复: `{target_uid}`*", parse_mode='MarkdownV2', reply_markup=ForceReply(selective=True))
            reply_context[sent.message_id] = target_uid
            
        elif action == 'history':
            await query.answer()
            history = db.get_history(target_uid)
            if history:
                lines = []
                for r in history:
                    stat = '✅' if r[2] else '⏳'
                    time_str = escape_md(str(r[1])[5:16])
                    msg_preview = escape_md(str(r[0])[:15])
                    lines.append(f"{stat} `{time_str}` {msg_preview}\.\.\.")
                msg = "📜 *历史记录*\n" + "\n".join(lines)
            else:
                msg = "📜 *历史记录*\n无记录"
            await query.message.reply_text(msg, parse_mode='MarkdownV2')
            
        elif action == 'done':
            db.mark_replied(target_uid, query.from_user.id)
            try: await query.edit_message_reply_markup(None)
            except: pass
            await query.answer("✅ 工单已关闭", show_alert=True)
            op_name = escape_md(get_full_name(query.from_user))
            await sync_team(context, query.from_user.id, f"✅ *[系统通知]*\n管理员 {op_name} 已标记用户 `{target_uid}` 为已处理。")
            
    except Exception as e:
        logger.error(f"Callback error: {e}")
        try: await query.message.reply_text(f"❌ 错误: {escape_md(str(e)[:50])}", parse_mode='MarkdownV2')
        except: pass

async def handle_admin_reply(update: Update, context):
    if update.effective_user.id not in CONFIG['OWNER_IDS'] or not update.message.reply_to_message: return
    target_uid = reply_context.get(update.message.reply_to_message.message_id)
    if not target_uid:
        try: target_uid = int(update.message.reply_to_message.text.split('`')[1])
        except: return await update.message.reply_text("❌ 无法识别对象")

    try:
        preview = ""
        sent = False
        if update.message.text: 
            await context.bot.send_message(target_uid, f"💬 客服: {update.message.text}")
            preview = update.message.text; sent = True
        elif update.message.photo: 
            await context.bot.send_photo(target_uid, update.message.photo[-1].file_id, caption=update.message.caption)
            preview = "[图片]"; sent = True
        elif update.message.voice: 
            await context.bot.send_voice(target_uid, update.message.voice.file_id)
            preview = "[语音]"; sent = True
        elif update.message.document: 
            await context.bot.send_document(target_uid, update.message.document.file_id)
            preview = "[文件]"; sent = True
        elif update.message.video: 
            await context.bot.send_video(target_uid, update.message.video.file_id)
            preview = "[视频]"; sent = True
            
        if sent:
            db.mark_replied(target_uid, update.effective_user.id)
            await update.message.reply_text("✅ 发送成功")
            if update.message.reply_to_message.message_id in reply_context:
                del reply_context[update.message.reply_to_message.message_id]
            op_name = escape_md(get_full_name(update.effective_user))
            sync_txt = f"ℹ️ *[同事操作]*\n管理员 {op_name} 回复了 `{target_uid}`:\n> {escape_md(preview[:20])}\.\.\."
            await sync_team(context, update.effective_user.id, sync_txt)
        else:
            await update.message.reply_text("❌ 不支持的格式")
    except Exception as e: await update.message.reply_text(f"❌ 发送失败: {e}")

async def post_init(app):
    async def cleanup():
        while True:
            await asyncio.sleep(3600)
            if len(reply_context) > 1000: reply_context.clear()
    asyncio.create_task(cleanup())

def main():
    logger.info("启动 Bot (v6.1)...")
    app = ApplicationBuilder().token(CONFIG['TOKEN']).post_init(post_init).build()
    
    app.add_handler(CommandHandler("start", start_command))
    app.add_handler(CommandHandler("stats", stats_command))
    app.add_handler(CommandHandler("history", history_command))
    app.add_handler(CommandHandler("help", start_command))
    
    app.add_handler(CallbackQueryHandler(handle_callback))
    app.add_handler(MessageHandler(filters.User(CONFIG['OWNER_IDS']) & filters.REPLY, handle_admin_reply))
    app.add_handler(MessageHandler(~filters.User(CONFIG['OWNER_IDS']), forward_message))
    app.run_polling()

if __name__ == '__main__': main()
EOFBOT
    
    chown "$BOT_USERNAME:$BOT_USERNAME" "$INSTALL_DIR/bot.py"
    chmod 755 "$INSTALL_DIR/bot.py"
}

setup_service() {
    log "配置服务..."
    if systemctl is-active --quiet tgbot; then systemctl stop tgbot; fi
    cat > /etc/systemd/system/tgbot.service <<EOF
[Unit]
Description=Telegram Bot
After=network.target
[Service]
Type=simple
User=$BOT_USERNAME
Group=$BOT_USERNAME
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/config.env
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/bot.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tgbot >/dev/null 2>&1
    systemctl start tgbot
}

create_logrotate() {
    log "配置日志轮转..."
    cat > /etc/logrotate.d/tgbot <<EOF
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 $BOT_USERNAME $BOT_USERNAME
    postrotate
        systemctl reload tgbot > /dev/null 2>&1 || true
    endscript
}
EOF
}

create_uninstall_script() {
    log "创建卸载工具..."
    cat > /usr/local/bin/uninstall_tgbot <<'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "需要 root 权限"; exit 1; fi
echo -e "\033[0;31m⚠️  警告：将彻底删除机器人及所有数据！\033[0m"
set +e
echo -n "确认卸载? (输入 y 确认): "
if [ -t 0 ]; then read -r answer; else read -r answer < /dev/tty; fi
set -e
if [[ ! "$answer" =~ ^[Yy]$ ]]; then echo "已取消"; exit 0; fi
systemctl stop tgbot; systemctl disable tgbot >/dev/null 2>&1
rm -f /etc/systemd/system/tgbot.service; systemctl daemon-reload
rm -rf /opt/tgbot /var/log/tgbot /var/lib/tgbot /etc/logrotate.d/tgbot /usr/local/bin/uninstall_tgbot
id tgbot &>/dev/null && userdel tgbot
echo -e "\033[0;32m✅ 卸载完成\033[0m"
EOF
    chmod +x /usr/local/bin/uninstall_tgbot
}

main() {
    if [ "$EUID" -ne 0 ]; then error "请使用 root 运行"; exit 1; fi
    get_user_inputs "$@"
    log "=== 开始部署 (v6.1 视觉增强版) ==="
    install_deps
    setup_env
    setup_python
    create_files
    setup_service
    create_logrotate
    create_uninstall_script
    success "部署完成！"
    echo -e "💡 常用命令: /stats, /history <id>, uninstall_tgbot"
}

main "$@"