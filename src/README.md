# Source Notes

`src/` 保留开发期辅助文件。当前可部署 App 在 `package/` 下，完整使用说明见项目根目录的 `README.md`。

早期 Voice AI 曾使用桌面 bridge；当前版本已经改为设备端直接调用 XiaoZhi STT 和 DeepSeek，并支持在设备上运行 DeepSeek 返回的 `ui_code`。
