# Voice AI for clocteck-holocubic

Voice AI 是给 clocteck-holocubic 小屏设备使用的本机语音助手 App。它运行在 320x240 的 LVGL 屏幕上，使用 XiaoZhi 组件完成录音编码和 STT，再调用 DeepSeek 生成中文回复。普通回复直接显示在屏幕上；当用户要求代码、动画或屏幕效果时，模型会返回 `ui_code`，设备会把这段 Lua/LVGL 代码直接运行成临时界面。

当前版本已经移除语音播报/TTS 逻辑，只保留屏幕显示和 `ui_code` 运行。

设备资料：[HoloCubic 平台介绍](https://clocteck.com/pages/holocubic) · [ClocTeck 官网](https://clocteck.com/)

## 功能

- 短按 `HOME` 录音，再短按停止并发送识别。
- 使用 `/sd/apps/xiaozhi/xiaozhi.so` 把 I2S PCM 编码为 Opus。
- 通过 XiaoZhi WebSocket 获得 STT 文本。
- 调用 DeepSeek `chat/completions` 生成回复。
- DeepSeek 返回 `reasoning_content` 且还没有最终内容时，屏幕显示 `推理中` 和推理文本。
- 代码/动画请求优先返回 `reply + ui_code`，设备直接加载临时 LVGL screen。
- 临时 `ui_code` 界面运行时，短按 `HOME` 会关闭界面并开始下一次录音。
- 内置网页配置页：`http://<device-ip>/voice_ai/`。

## 目录

```text
package/
  main.lua                 App 入口
  app.info                 Holocubic App 描述
  config.example.json      配置示例
  assets/buddy/            屏幕状态动画
  font/                    字体构建脚本和字符集
src/
  font/                    字体构建脚本副本
```

## 安装

把 `package` 目录内容放到设备 SD 卡：

```text
/sd/apps/voice_ai/
```

设备上还需要 XiaoZhi App 的这些文件：

```text
/sd/apps/xiaozhi/xiaozhi.so
/sd/apps/xiaozhi/protocol.lua
/sd/apps/xiaozhi/identity.lua
```

复制配置示例：

```text
/sd/apps/voice_ai/config.example.json -> /sd/apps/voice_ai/config.json
```

然后填写：

- `xiaozhi.websocket.url`
- `xiaozhi.websocket.token`
- `deepseek.api_key`
- 需要时调整 `deepseek.base_url` 和 `deepseek.model`

Voice AI 也会优先复用这些配置来源：

```text
XiaoZhi STT: /sd/apps/xiaozhi/config.json -> /sd/apps/voice_ai/config.json -> defaults
DeepSeek LLM: /sd/apps/holocubic-lua-claw/config.json -> /sd/apps/voice_ai/config.json -> defaults
```

## 使用

1. 在 clocteck-holocubic 上打开 Voice AI。
2. 短按 `HOME` 开始录音。
3. 再短按 `HOME` 停止录音并等待回复。
4. 说“写一个旋转立方体动画”这类请求时，DeepSeek 会被要求返回可运行的 `ui_code`，App 会直接加载动画界面。
5. 长按 `HOME` 退出 App。

网页配置页：

```text
http://<device-ip>/voice_ai/
```

## 实现流程

```text
I2S 麦克风 PCM
  -> xiaozhi.so encode_i2s()
  -> Opus 帧
  -> XiaoZhi WebSocket
  -> STT 文本
  -> DeepSeek chat/completions
  -> 普通 reply 显示到 LVGL
  -> 或 ui_code 编译运行成临时 LVGL screen
```

`ui_code` 的期望形状：

```lua
return function(ctx)
  local screen = ctx.new_screen(0x000000)
  local cvs = ctx.canvas(screen, 0, 0, ctx.SCREEN_W, ctx.SCREEN_H, 0x000000)

  local t = 0
  ctx.every(50, function()
    t = t + 0.08
    ctx.begin(cvs)
    ctx.clear(cvs, 0x000000)
    ctx.line(cvs, 60, 60, 220, 180, 0x55D6FF, 255, 2)
    ctx.finish(cvs)
  end)

  return {
    screen = screen,
    cleanup = function() end
  }
end
```

`ui_code` 运行在受限环境中，只暴露必要的 Lua 基础库、LVGL 绘图函数和 `ctx` 辅助函数，不开放文件、HTTP、`require`、`os`、`io`、`debug` 等接口。

## 字体

App 默认尝试加载：

```text
/sd/apps/voice_ai/font/msyh_cn_13.bin
```

仓库不分发由 Microsoft YaHei 生成的二进制字体文件。请在本机拥有相应字体授权的前提下运行：

```powershell
.\package\font\build_msyh_cn_13.ps1
```

也可以替换成你有权分发的中文字体，并按脚本生成 LVGL 字体 bin。

## 许可证

本项目使用 GNU General Public License v3.0，详见 [LICENSE](LICENSE)。
