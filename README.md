# 局域网快传 Flutter 客户端（对照 PC v7）

对等实现 `lan_transfer_gui_v7.py` 的 **LANT2024** 协议核心。

## 目录

```
lib/
  constants.dart     协议/发现常量
  main.dart          入口与主题
  models/            设置、传输历史
  protocol/          帧头、AES、校验、限速、IO
  net/               发现、接收、发送
  http_share/        HTTP 共享扫码浏览
  ui/                页面
    widgets/         无状态控件（卡片、设备选择、日志等）
android/             Android 工程（含 NativeDiscovery UDP）
```

## 已实现

- 接收 / 发送（TCP，`LANT2024` + JSON meta）
- 断点续传、差异同步签名、MD5/SHA256 校验
- AES-CBC（PBKDF2-HMAC-SHA256，100000 次，与 PC 一致）
- 文件夹 zip 打包/解压
- UDP 设备发现（固定 `5100`，`LANT_DISCOVER_v8`；双方需同版本）
- 可改保存目录（持久化）
- 限速、传输历史、日志与进度
- HTTP 共享伴侣：扫码 + 目录浏览下载

## 刻意不做（PC 专属）

- 静态 IP / DHCP / 多网卡 PowerShell
- 悬浮球 / matplotlib 速度曲线
- 完成后关机休眠

## 联调

1. PC 运行 `lan_transfer_gui_v7.py`，设同一端口
2. 手机与 PC 同网段（或直连 `192.168.99.x`）
3. 一端接收、一端发送；或 PC「HTTP共享」→ App 扫码

## 依赖

Flutter SDK：`D:\flutter`  
工程：`D:\AndroidProject\lan_transfer_client`
