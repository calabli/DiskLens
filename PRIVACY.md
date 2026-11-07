# Privacy

**English** · [中文](#隐私说明)

DiskLens has no account, no analytics and no crash reporting. It has no server of its own, and it never uploads your files, file names or scan results.

## Full Disk Access

macOS asks you to grant this because a disk tool has to read everywhere. DiskLens uses it to measure folders, and to compare files when you search for duplicates or similar photos. It doesn't copy or send what it reads.

## What stays on your Mac

| What | Where |
| --- | --- |
| Saved scans, including file names and sizes | `~/Library/Caches/app.disklens.DiskLens` |
| Cleanup history, downloaded rules and background records | `~/Library/Application Support/app.disklens.DiskLens` |
| Settings | macOS preferences |

If you turn on background recording, a helper records which apps write to disk and which folders grow. It keeps these records for 90 days. It is off until you turn it on.

## What goes over the network

DiskLens only downloads public files:

| What | From | Turn off in Settings |
| --- | --- | --- |
| New version information and update packages | `calabli.github.io`, `api.github.com`, `github.com` | Check for updates automatically |
| Cleanup rule updates | `calabli.github.io` | Update cleanup rules automatically |

Updates and rules are verified with a signature before use. These requests send nothing about your disk. Like any web request, they reach GitHub with your IP address, and GitHub's own privacy policy applies to them.

---

# 隐私说明

[English](#privacy) · **中文**

DiskLens 没有账号、统计分析和崩溃上报。它没有自己的服务器，也不会上传你的文件、文件名或扫描结果。

## 完全磁盘访问权限

磁盘工具要读取所有位置，所以 macOS 要求你授权。DiskLens 用它来测量文件夹大小，并在查找重复文件或相似照片时比较文件。读到的内容不会被复制或发送出去。

## 留在你 Mac 上的数据

| 内容 | 位置 |
| --- | --- |
| 保存的扫描结果，包括文件名和大小 | `~/Library/Caches/app.disklens.DiskLens` |
| 清理记录、下载的规则和后台记录 | `~/Library/Application Support/app.disklens.DiskLens` |
| 设置 | macOS 偏好设置 |

如果你开启后台记录，助手程序会记录哪些应用在写入磁盘、哪些文件夹在增长，记录保留 90 天。这项功能在你开启之前不会运行。

## 会联网的内容

DiskLens 只下载公开文件：

| 内容 | 来源 | 在设置里关闭 |
| --- | --- | --- |
| 新版本信息和更新包 | `calabli.github.io`、`api.github.com`、`github.com` | 自动检查更新 |
| 清理规则更新 | `calabli.github.io` | 自动更新清理规则 |

更新包和规则都要先通过签名校验才会使用。这些请求不包含任何磁盘信息。和所有网络请求一样，GitHub 会看到你的 IP 地址，并适用 GitHub 自己的隐私政策。
