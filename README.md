curl -sSL https://raw.githubusercontent.com/easonhunt7/singboXray/main/deploy.sh -o deploy.sh && chmod +x deploy.sh && \
./deploy.sh "x" "443" "8001" "your-domain.com" "your-argo-token"

第 1 个值 ("x")：NaiveProxy 端口（n = 不部署 / x = 随机 / 指定端口）

第 2 个值 ("443")：xHTTP 直连端口（n = 不部署 / x = 随机 / 指定端口）

第 3 个值 ("8001")：Argo 回源端口

第 4 个值 ("your-domain.com")：Argo 固定隧道域名

第 5 个值 ("your-argo-token")：Argo 隧道 Token
