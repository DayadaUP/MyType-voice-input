# MyType 语音输入法

MyType 是一款 macOS 语音输入工具。
你可以直接按设定好的快捷键开始说话，把语音识别成文字后自动写入当前正在输入的文本框。

这个公开仓库只保留与软件本身直接相关的内容：

- macOS 应用源码
- 构建与打包脚本
- 单元测试
- 核心技术说明文档

这个仓库不会包含以下内容：

- 私人 API 或云端密钥
- 本地模型文件与虚拟环境
- 个人样本、开发日志、阶段性工作记录
- 设计源文件、截图素材与品牌资源

## 下载

- 直接下载 DMG：
  [MyType-0.1.0.dmg](https://github.com/DayadaUP/MyType/releases/download/v0.1.0/MyType-0.1.0.dmg)
- Release 页面：
  [GitHub Releases](https://github.com/DayadaUP/MyType/releases)

## 主要能力

- 通过快捷键启动语音输入
- 支持本地识别、云端识别和混合模式
- 支持实时预览与最终文本插入
- 支持个人词库与语气词过滤
- 支持 API 自定义配置与连通性测试
- 支持本地模型下载、部署与删除

## 快速开始

```bash
cd apps/mac-ime
swift build
swift run MyTypeIMEDemo
```

## 打包

```bash
cd apps/mac-ime
bash Scripts/package_demo_app.sh
```

默认打包产物会输出到 `apps/mac-ime/dist/`。

## 仓库结构

- `apps/mac-ime`
  当前 macOS 应用实现
- `core/asr`
  识别层说明
- `core/text-processor`
  文本后处理说明
- `core/lexicon`
  词库能力说明
- `docs`
  公开保留的产品与技术文档

## 文档入口

- [macOS 应用说明](apps/mac-ime/README.md)
- [产品概览](docs/PRODUCT_OVERVIEW.md)
- [技术架构](docs/TECHNICAL_ARCHITECTURE.md)
- [识别模式说明](docs/RUNTIME_MODES.md)
- [ASR 说明](core/asr/README.md)
- [文本后处理说明](core/text-processor/README.md)
- [词库说明](core/lexicon/README.md)

## 隐私说明

- 云端模式默认不附带任何 API 凭证，使用者需要自行配置。
- 本地模式速度会受设备性能、系统负载和模型档位影响。
- 首次公开版本仅保留软件相关文件，不包含个人记录或历史素材。

---

## English

MyType is a macOS voice input project focused on making speech-to-text feel practical in everyday desktop workflows.

This public repository intentionally keeps only software-related materials:

- macOS application source code
- build and packaging scripts
- unit tests
- core technical documentation

The repository does not include:

- private API credentials
- local model files or virtual environments
- personal notes, sample records, or development logs
- design source files, screenshots, or branded assets

### Download

- Direct DMG download:
  [MyType-0.1.0.dmg](https://github.com/DayadaUP/MyType/releases/download/v0.1.0/MyType-0.1.0.dmg)
- Releases page:
  [GitHub Releases](https://github.com/DayadaUP/MyType/releases)

### Quick Start

```bash
cd apps/mac-ime
swift build
swift run MyTypeIMEDemo
```

### Packaging

```bash
cd apps/mac-ime
bash Scripts/package_demo_app.sh
```

### Docs

- [macOS app guide](apps/mac-ime/README.md)
- [Product overview](docs/PRODUCT_OVERVIEW.md)
- [Technical architecture](docs/TECHNICAL_ARCHITECTURE.md)
- [Recognition modes](docs/RUNTIME_MODES.md)

### Privacy

- Cloud mode ships without bundled API credentials.
- Local mode responsiveness depends on hardware performance, system load, and model size.
- This open-source snapshot excludes personal materials and historical work logs.
