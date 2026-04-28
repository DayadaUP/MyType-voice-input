# 技术架构

## 目录结构

- `apps/mac-ime/Sources/AudioEngine`
  负责录音与音频采集
- `apps/mac-ime/Sources/ASRAdapter`
  负责本地识别、云端识别与接口适配
- `apps/mac-ime/Sources/TextProcessor`
  负责文本清洗、标点、数字日期与终态润色
- `apps/mac-ime/Sources/Lexicon`
  负责个人词库、纠错学习与持久化
- `apps/mac-ime/Sources/IMEHost`
  负责输入控制、焦点注入与兼容性策略
- `apps/mac-ime/Sources/MyTypeIMEDemo`
  负责应用入口、设置页、实时预览与历史管理

## 主流程

1. 用户通过快捷键开始录音。
2. `AudioEngine` 采集音频。
3. `ASRAdapter` 根据配置选择本地或云端识别。
4. 识别结果进入 `TextProcessor` 做后处理。
5. `Lexicon` 参与个性化修正。
6. `IMEHost` 将最终文本插入当前焦点输入区域。

## 本地识别

- 通过 Python 脚本桥接本地转写流程
- 支持将模型与运行环境部署到本机目录
- 本地速度受设备性能、系统负载和模型大小影响

## 云端识别

- 不在仓库中附带任何云端密钥
- 由用户在设置页中自行填写 endpoint、key 与模型名
- 当前工程对 Doubao 风格的流式语音接口支持更完整

## 可靠性设计

- 实时预览与最终提交分开处理
- 插入前后带有稳定性保护与重复提交防护
- 词库学习与设置项使用本地持久化存储
