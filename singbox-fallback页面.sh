sudo bash -c '
# 1. 创建网页根目录并写入简约的单文件伪装页面
mkdir -p /var/www/html
cat << "EOF" > /var/www/html/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;max-width:650px;margin:100px auto;padding:0 20px;color:#333;line-height:1.6;background:#fafafa;} .card{background:#fff;padding:40px;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,0.05);} h1{font-size:20px;margin-top:0;color:#111;} p{color:#666;font-size:14px;}</style>
</head>
<body>
    <div class="card">
        <h1>System Operational</h1>
        <p>Welcome to this network node. All systems running normally.</p>
    </div>
</body>
</html>
EOF

# 2. 使用 Python 自动将 fallback 回落配置注入到 sing-box 配置文件中
python3 -c \'
import json
path = "/usr/local/singbox_naive/config.json"
with open(path, "r") as f:
    data = json.load(f)
for ib in data.get("inbounds", []):
    if "tls" in ib:
        ib["tls"]["fallback"] = {"address": "127.0.0.1", "port": 8080}
        break
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print("Config updated successfully.")
\'

# 3. 杀死可能残留的旧 python 进程并启动后台静态网页服务
pkill -f "http.server 8080"
nohup python3 -m http.server 8080 --directory /var/www/html > /dev/null 2>&1 &

# 4. 重启 sing-box 进程或服务使配置生效
systemctl restart sing-box 2>/dev/null || pkill -f sing-box
'
