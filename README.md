# MPV Night Player

面向 iPhone / iPad 的本地视频播放器，最低 iOS 15，目标测试系统 iOS 16.4。使用 **MPVKit 1.0.0**（固定版本）、libmpv、gpu-next 和 MoltenVK/Metal。

## 1.0.2 更新
- 文件选择器使用系统导入副本模式，显示文件扩展名，避免依赖文件提供商的原位打开能力。
- 系统交付副本后直接读取，不再重复协调文件提供商。
- 新增“文件”App 的分享/打开方式入口，可将视频交给 MPV Night Player。
- 状态文字区分“等待选择器交付”和“已收到文件”，取消选择也有明确反馈。
- 1.0.1 相册视频已获用户确认可播放；文件 MOV 点选问题需要在新版本真机复测。

## 1.0.1 更新
- 新增 Photos 相册视频选择器，无需授予整个相册的读取权限。
- 文件通过协调读取复制到应用临时目录后播放，相册临时文件在回调结束前保存。
- 导入在后台进行；替换视频后删除上一份导入副本，需要预留视频大小的空间。
- 加载完成后再启动播放，避免加载与暂停状态的异步竞态。
- 新增“查看播放错误”，可复制底层警告/错误，便于真机排查。
- 尚未取得用户原始播放故障的错误详情，不能将编译通过视为真机问题已经解决。

## 功能
- UIDocumentPicker 打开 MP4、MOV、MKV 等本地视频，包括文件提供商中的文件。
- 播放、暂停、播完重播；后台自动暂停，耳机拔出时暂停。
- Brightness、Gamma、Contrast、Saturation 实时调整（mpv 原生 -100…100，默认 0）。
- Reset 一键恢复；横屏左右布局，竖屏上下布局，控制面板可滚动。
- 解码或文件访问失败时显示错误。支持的实际编码取决于 MPVKit/FFmpeg。
- 参数改变视频画面，不改变系统屏幕亮度。本版未加入去噪/锐化。

## 下载和安装
1. 打开 [Actions](https://github.com/guans1976/MPVNightPlayer/actions/workflows/build-ipa.yml)，选择成功的运行。
2. 下载 **MPVNightPlayer-unsigned** artifact，解压 ZIP。
3. 在已安装 TrollStore 的兼容设备上，用 TrollStore 打开 `MPVNightPlayer-unsigned.ipa`。
4. 打开应用，点 **Open Video / 打开**，选择视频并调整滑块；也可点 **Photos / 从相册选择视频**。

IPA 未使用 Apple 开发者证书签名；TrollStore 在安装时处理签名。此构建不需要私有权限、越狱权限或开发者账号。编译成功不能替代 iOS 16.4 真机测试。

## 构建
在 macOS 上用 Xcode 16 或更新版本打开 `MPVNightPlayer.xcodeproj`，选择 **MPVNightPlayer** scheme。Swift Package Manager 自动获取固定的 MPVKit 1.0.0 二进制依赖。

```sh
xcodebuild build -project MPVNightPlayer.xcodeproj -scheme MPVNightPlayer \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" ARCHS=arm64
mkdir -p build/ipa/Payload
ditto build/DerivedData/Build/Products/Release-iphoneos/MPVNightPlayer.app build/ipa/Payload/MPVNightPlayer.app
(cd build/ipa && zip -qry MPVNightPlayer-unsigned.ipa Payload)
```

GitHub Actions 在 macos-15 上执行依赖解析、无签名 iphoneos 构建、arm64 检查、IPA ZIP 完整性检查，并上传 IPA、SHA-256 校验和与构建日志。可手动 Run workflow，也会在 main 推送时自动执行。

## 真机验收清单
- iOS 16.4 + TrollStore 安装并启动。
- 从“我的 iPhone”打开 MP4/MOV/MKV；也测试文件名带中文、空格。
- 暂停/继续/重播；拖动四个滑块时画面实时变化；Reset 后均为 0。
- 播放和暂停时分别旋转横竖屏；面板滚动时按钮均可访问。
- 打开第二个文件；取消文件选择；选择不支持的文件时显示错误。
- 锁屏/返回、来电中断、耳机拔出；返回前台后由用户按 Play 继续。
- 测试文件提供商/iCloud 文件的访问权限和下载等待。
- HDR、4K、高码率视频的画面/音画同步/性能需要真机确认。

## 第三方依赖
采用 MPVKit 的非 GPL 产品 `MPVKit`。Metal 接入方式参考 [MPVKit 官方 iOS Demo](https://github.com/mpvkit/MPVKit/tree/1.0.0/Demo/Demo-iOS)，本仓库应用代码为独立实现。MPVKit/libmpv 及 FFmpeg 等组件保留各自许可证；对应源码、构建脚本和组件版本见 [MPVKit 1.0.0](https://github.com/mpvkit/MPVKit/tree/1.0.0) 与其 [LICENSE](https://github.com/mpvkit/MPVKit/blob/1.0.0/LICENSE)。本仓库提供完整应用源码，允许重新构建和替换依赖。
