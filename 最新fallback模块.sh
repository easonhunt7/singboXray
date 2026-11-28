# ==================== 自动化集成伪装页与 Fallback 模块 ====================
echo "正在配置网页伪装与 Fallback 回落..."

# 1. 写入更自然的伪装单页
mkdir -p /var/www/html
cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dev & Notes</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 680px; margin: 80px auto; padding: 0 20px; color: #333; line-height: 1.7; background: #ffffff; }
        h1 { font-size: 22px; border-bottom: 1px solid #eaeaea; padding-bottom: 12px; margin-bottom: 24px; color: #111; }
        .post { margin-bottom: 30px; }
        .date { color: #888; font-size: 13px; margin-bottom: 6px; }
        p { color: #555; font-size: 14px; margin: 0; }
    </style>
</head>
<body>
    <h1>Notes & Snippets</h1>
    <div class="post">
        <div class="date">November 28, 2026</div>
        <p>A simple personal collection of scripts, configuration snippets, and daily technical notes.</p>
    </div>
</body>
</html>
EOF

# 2. 用 Python 自动将 fallback 注入到 sing-box 的 config.json 中
python3 -c '
import json, os
path = "/usr/local/singbox_naive/config.json"
if os.path.exists(path):
    with open(path, "r") as f:
        data = json.load(f)
    for ib in data.get("inbounds", []):
        if "tls" in ib:
            ib["tls"]["fallback"] = {"address": "127.0.0.1", "port": 8080}
            break
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print("Fallback injected successfully.")
else:
    print("Config path not found, skipped.")
'

# 3. 启动后台静态网页服务
pkill -f "http.server 8080"
nohup python3 -m http.server 8080 --directory /var/www/html > /dev/null 2>&1 &

# 4. 重启 sing-box 服务
systemctl restart sing-box 2>/dev/null || pkill -f sing-box
echo "伪装页与 Fallback 部署完成！"
# =========================================================================
