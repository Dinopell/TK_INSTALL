# TK_INSTALL

子台**唯一对用户公开**的安装脚本仓库。仅包含薄入口 `static/tk/install.sh`，不含 jar/zip 与完整部署逻辑（由 GHCR installer 镜像执行）。

总台部署脚本在 **TK_master** 仓库，**不放在本仓库**，须运维 SSH/scp 手动上传执行。

## 子台用户：安装 / 升级

从本仓库获取脚本（建议仓库设为 **Private**，仅授权用户可拉 raw）：

```bash
curl -fsSL https://raw.githubusercontent.com/Dinopell/TK_INSTALL/main/static/tk/install.sh -o /root/install.sh
chmod +x /root/install.sh
bash /root/install.sh
```

**私有仓库**（PAT 须含 `repo` 读权限）：

```bash
curl -fsSL -H "Authorization: Bearer ghp_你的PAT" \
  https://raw.githubusercontent.com/Dinopell/TK_INSTALL/main/static/tk/install.sh -o /root/install.sh
chmod +x /root/install.sh
bash /root/install.sh
```

指定镜像版本（运维发版时告知 `IMAGE_TAG`）：

```bash
export IMAGE_REGISTRY=ghcr.io/dinopell
export IMAGE_TAG=20260618
bash /root/install.sh
```

私有 GHCR 镜像须先登录：

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_USER --password-stdin
```

更多说明见同级目录 **TK_learn/README.md**（用户操作手册）。

## 运维：更新本仓库脚本

安装脚本源码在 `TK_learn/user/install.sh`，发版前同步到本仓库：

```bash
cd ../TK_learn
bash ops/sync-to-tk-install.sh
cd ../TK_INSTALL
git add static/tk/install.sh
git commit -m "chore: sync install.sh from TK_learn"
git push origin main
```

## 与总台的关系

| 项目 | 获取方式 |
|------|----------|
| 子台 `install.sh` | **本仓库** `static/tk/install.sh`（GitHub） |
| 总台 `deploy.sh` | **TK_master** `user/deploy.sh`，运维 **scp 手动上传**，不公开 curl |

总台不提供任何安装脚本下载链接。
