if _G.VOICE_AI_APP and _G.VOICE_AI_APP.stop then
  pcall(function() _G.VOICE_AI_APP.stop("reload") end)
end

VOICE_AI_APP = {
  VERSION = "2026-07-04-local-xiaozhi-deepseek-fix3",
  SCREEN_W = 320,
  SCREEN_H = 240,
  APP_DIR = "/sd/apps/voice_ai",
  XIAOZHI_APP_DIR = "/sd/apps/xiaozhi",
  CLAW_APP_DIR = "/sd/apps/holocubic-lua-claw",
  DEFAULT_DEEPSEEK_BASE_URL = "https://api.deepseek.com/v1",
  DEFAULT_DEEPSEEK_MODEL = "deepseek-chat",
  I2S_ID = 0,
  USE_GIF = true,
  WEB_MAX_HANDLERS = 16,
}

local APP = VOICE_AI_APP
APP.LEGACY_SYSTEM_PROMPT = "你是运行在小屏设备上的中文语音助手。回答要简洁自然，优先 100 字以内。"
APP.DEFAULT_SYSTEM_PROMPT = table.concat({
  "你是 Voice AI，Holocubic 本机小屏语音助手。",
  "STT 可能有错，按口语理解；不确定就问一句。",
  "最新请求优先；默认中文，简短自然，适合 320x240 屏，普通回答 100 字内。",
  "用户要求写代码、脚本、动画或屏幕效果时，优先返回 reply + ui_code，让设备直接运行界面代码。",
  "不要输出推理过程、内部分析、元叙述或“我应该/我们应该”。",
  "接口文档只说明能力边界；没有实际工具结果时，不要声称已执行接口、文件、设备或实时查询。",
  "时效/高风险事实不编造，说明需实时确认。",
}, "\n")
local MAIN_STYLE = (rawget(_G, "LV_PART_MAIN") or 0) | (rawget(_G, "LV_STATE_DEFAULT") or 0)
local ALIGN_LEFT = rawget(_G, "LV_TEXT_ALIGN_LEFT") or 0
local FONT_12 = rawget(_G, "LV_FONT_MONTSERRAT_12") or 12
local LABEL_LONG_CLIP = rawget(_G, "LV_LABEL_LONG_CLIP") or rawget(_G, "LABEL_LONG_CLIP")
local LABEL_LONG_WRAP = rawget(_G, "LV_LABEL_LONG_WRAP") or LABEL_LONG_CLIP

local C = {
  bg = 0x000000,
  line = 0x242B33,
  text = 0xF4F7FA,
  sub = 0xAAB4C2,
  dim = 0x66717F,
  cyan = 0x55D6FF,
  green = 0x55E39A,
  yellow = 0xF5C65B,
  red = 0xFF6B5F,
}

APP.running = true
APP.root = nil
APP.ui = {}
APP.timers = {}
APP.font_handles = {}
APP.ui_code = nil
APP.protocol = nil
APP.ProtocolModule = nil
APP.voice = nil
APP.voice_ready = false
APP.audio_pending = ""
APP.frame_pcm_bytes = 1440
APP.frame_raw_bytes = 2880
APP.read_raw_bytes = 2880
APP.request_id = 0
APP.routes = {}
APP.route_base = (app and app.route_base and app.route_base()) or "/voice_ai"
if APP.route_base == "" then APP.route_base = "/voice_ai" end
APP.config_sources = {}
APP.connect_goal = nil
APP.request_needs_ui_code = false

APP.config = {
  xiaozhi_app_dir = APP.XIAOZHI_APP_DIR,
  xz_module = APP.XIAOZHI_APP_DIR .. "/xiaozhi.so",
  xiaozhi_ws_url = "",
  xiaozhi_token = "",
  xiaozhi_version = 3,
  xiaozhi_buffer_size = 8192,
  xiaozhi_timeout_ms = 10000,
  xiaozhi_keep_connected = true,
  xiaozhi_reconnect_ms = 5000,

  audio_rate = 12000,
  audio_frame_ms = 60,
  audio_bits = 32,
  audio_mic_pack = "b23",
  audio_gain_shift = 2,
  audio_bitrate = 12000,
  audio_complexity = 0,
  audio_buffer_count = 8,
  audio_poll_ms = 55,
  audio_read_wait_ms = 0,

  max_record_ms = 10000,
  stt_timeout_ms = 12000,

  deepseek_base_url = APP.DEFAULT_DEEPSEEK_BASE_URL,
  deepseek_api_key = "",
  deepseek_model = APP.DEFAULT_DEEPSEEK_MODEL,
  deepseek_timeout_ms = 35000,
  deepseek_max_tokens = 512,
  interface_docs_enabled = true,
  interface_docs_path = APP.CLAW_APP_DIR .. "/capabilities.json",
  interface_docs_max_bytes = 0,
  system_prompt = APP.DEFAULT_SYSTEM_PROMPT,
  reply_limit = 100,
  use_gif = APP.USE_GIF,
}

APP.state = {
  mode = "idle",
  shown_gif_state = nil,
  record_started_ms = 0,
  send_frames = 0,
  reasoning_only = false,
  last_error = "",
  transcript = "",
  reply = "按下说话",
}

local UI = APP.ui
local S = APP.state

local function call(fn, ...)
  if fn then
    return pcall(fn, ...)
  end
  return false
end

local function now_ms()
  if millis then
    local ok, value = pcall(millis)
    if ok and type(value) == "number" then return value end
  end
  if tmr and tmr.now then
    local ok, value = pcall(function() return tmr.now() end)
    if ok and type(value) == "number" then return math.floor(value / 1000) end
  end
  return 0
end

local function text_or(value, fallback)
  if value == nil then return fallback or "" end
  local text = tostring(value)
  if text == "" then return fallback or "" end
  return text
end

local function trim(text)
  text = text_or(text, "")
  return text:match("^%s*(.-)%s*$") or ""
end

local function clamp(n, low, high)
  n = tonumber(n) or 0
  if n < low then return low end
  if n > high then return high end
  return n
end

local function mark_source(key, source)
  APP.config_sources[key] = source or "default"
end

local function set_config_string(key, value, source, allow_empty)
  if type(value) ~= "string" then return false end
  if value == "" and not allow_empty then return false end
  APP.config[key] = value
  mark_source(key, source)
  return true
end

local function set_config_number(key, value, low, high, source)
  local n = tonumber(value)
  if not n then return false end
  APP.config[key] = clamp(n, low, high)
  mark_source(key, source)
  return true
end

local function set_config_bool(key, value, source)
  if type(value) ~= "boolean" then return false end
  APP.config[key] = value
  mark_source(key, source)
  return true
end

local function sd_to_lv(path)
  if type(path) == "string" and path:sub(1, 4) == "/sd/" then
    return "/" .. path:sub(5)
  end
  return path
end

local function file_exists(path)
  if file and file.exists then
    local ok, exists = pcall(function() return file.exists(path) end)
    if ok and exists then return true end
  end
  if file and file.stat then
    local ok, st = pcall(function() return file.stat(path) end)
    return ok and st ~= nil
  end
  return false
end

local function read_text_file(path)
  if type(path) ~= "string" or path == "" then return "" end
  if not file or not file.getcontents then return "" end
  local ok, raw = pcall(function() return file.getcontents(path) end)
  if ok and type(raw) == "string" then return raw end
  return ""
end

local function safe_json_decode(raw)
  if not raw or raw == "" then
    return nil, "empty json"
  end
  if json and json.decode then
    local ok, doc, err = pcall(function()
      local value, decode_err = json.decode(raw)
      return value, decode_err
    end)
    if ok and doc then return doc, nil end
    if not ok then return nil, tostring(doc) end
  end
  if sjson and sjson.decode then
    local ok, doc = pcall(function() return sjson.decode(raw) end)
    if ok and doc then return doc, nil end
  end
  return nil, "json decode failed"
end

local function json_escape(text)
  text = text_or(text, "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  return text
end

local function is_array(value)
  if type(value) ~= "table" then return false end
  local n = 0
  for k in pairs(value) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    if k > n then n = k end
  end
  for i = 1, n do
    if value[i] == nil then return false end
  end
  return true
end

local encode_value
encode_value = function(value)
  local typ = type(value)
  if typ == "string" then
    return '"' .. json_escape(value) .. '"'
  elseif typ == "number" or typ == "boolean" then
    return tostring(value)
  elseif typ == "table" then
    local out = {}
    if is_array(value) then
      for i = 1, #value do
        out[#out + 1] = encode_value(value[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, v in pairs(value) do
      if type(k) == "string" and v ~= nil then
        out[#out + 1] = '"' .. json_escape(k) .. '":' .. encode_value(v)
      end
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

local function safe_json_encode(value)
  if json and json.encode then
    local ok, raw, err = pcall(function()
      local text, encode_err = json.encode(value)
      return text, encode_err
    end)
    if ok and raw then return raw, nil end
    if not ok then return nil, tostring(raw) end
    if err then return nil, tostring(err) end
  end
  if sjson and sjson.encode then
    local ok, raw = pcall(function() return sjson.encode(value) end)
    if ok and raw then return raw, nil end
  end
  return encode_value(value), nil
end

local function apply_xiaozhi_defaults(cfg)
  if type(cfg) ~= "table" then return end
  if type(cfg.APP_DIR) == "string" and cfg.APP_DIR ~= "" then
    APP.config.xiaozhi_app_dir = cfg.APP_DIR
    mark_source("xiaozhi_app_dir", "xiaozhi")
  end
  if type(cfg.XZ_MODULE) == "string" and cfg.XZ_MODULE ~= "" then
    APP.config.xz_module = cfg.XZ_MODULE
    mark_source("xz_module", "xiaozhi")
  else
    APP.config.xz_module = APP.config.xiaozhi_app_dir .. "/xiaozhi.so"
  end
  if type(cfg.websocket) == "table" then
    set_config_string("xiaozhi_ws_url", cfg.websocket.url, "xiaozhi")
    if type(cfg.websocket.token) == "string" and (cfg.websocket.token ~= "" or APP.config.xiaozhi_ws_url ~= "") then
      set_config_string("xiaozhi_token", cfg.websocket.token, "xiaozhi", true)
    end
    set_config_number("xiaozhi_version", cfg.websocket.version, 1, 3, "xiaozhi")
    set_config_number("xiaozhi_buffer_size", cfg.websocket.buffer_size, 1024, 65536, "xiaozhi")
    set_config_number("xiaozhi_timeout_ms", cfg.websocket.timeout_ms, 3000, 30000, "xiaozhi")
  end
  if type(cfg.AUDIO) == "table" then
    set_config_number("audio_rate", cfg.AUDIO.rate, 8000, 48000, "xiaozhi")
    set_config_number("audio_frame_ms", cfg.AUDIO.frame_ms, 20, 120, "xiaozhi")
    set_config_number("audio_bits", cfg.AUDIO.mic_bits, 16, 32, "xiaozhi")
    set_config_string("audio_mic_pack", cfg.AUDIO.tx_mic_pack or cfg.AUDIO.mic_pack, "xiaozhi")
    set_config_number("audio_gain_shift", cfg.AUDIO.tx_gain_shift or cfg.AUDIO.mic_gain_shift, 0, 8, "xiaozhi")
    set_config_number("audio_bitrate", cfg.AUDIO.bitrate, 6000, 64000, "xiaozhi")
    set_config_number("audio_complexity", cfg.AUDIO.complexity, 0, 10, "xiaozhi")
    set_config_number("audio_buffer_count", cfg.AUDIO.rx_buffer_count, 2, 16, "xiaozhi")
    set_config_number("audio_poll_ms", cfg.AUDIO.tx_poll_ms or cfg.AUDIO.poll_ms, 10, 200, "xiaozhi")
    set_config_number("audio_read_wait_ms", cfg.AUDIO.tx_read_wait_ms, 0, 200, "xiaozhi")
  end
end

local function load_xiaozhi_defaults()
  local path = APP.config.xiaozhi_app_dir .. "/config.lua"
  local ok, mod = pcall(dofile, path)
  if not ok or type(mod) ~= "table" then return end
  local loaded = mod
  if mod.load then
    local ok_load, cfg = pcall(function() return mod.load() end)
    if ok_load and type(cfg) == "table" then
      loaded = cfg
    end
  end
  apply_xiaozhi_defaults(loaded)
end

local function load_claw_llm_defaults()
  if not file or not file.getcontents then return end
  local raw = file.getcontents(APP.CLAW_APP_DIR .. "/config.json")
  local cfg = safe_json_decode(raw)
  if type(cfg) ~= "table" then return end
  set_config_string("deepseek_base_url", cfg.llm_base_url, "holocubic-lua-claw")
  set_config_string("deepseek_api_key", cfg.llm_api_key, "holocubic-lua-claw")
  set_config_string("deepseek_model", cfg.llm_model, "holocubic-lua-claw")
  set_config_number("deepseek_timeout_ms", cfg.llm_timeout_ms, 5000, 120000, "holocubic-lua-claw")
end

local function preload_config_paths(cfg)
  if type(cfg) ~= "table" then return end
  if type(cfg.xiaozhi_app_dir) == "string" and cfg.xiaozhi_app_dir ~= "" then
    APP.config.xiaozhi_app_dir = cfg.xiaozhi_app_dir
    APP.config.xz_module = cfg.xiaozhi_app_dir .. "/xiaozhi.so"
  end
  if type(cfg.xiaozhi) == "table" and type(cfg.xiaozhi.app_dir) == "string" and cfg.xiaozhi.app_dir ~= "" then
    APP.config.xiaozhi_app_dir = cfg.xiaozhi.app_dir
    APP.config.xz_module = cfg.xiaozhi.app_dir .. "/xiaozhi.so"
  end
end

local function apply_voice_config(cfg)
  if type(cfg) ~= "table" then return end

  if type(cfg.xiaozhi_app_dir) == "string" and cfg.xiaozhi_app_dir ~= "" then
    APP.config.xiaozhi_app_dir = cfg.xiaozhi_app_dir
    APP.config.xz_module = cfg.xiaozhi_app_dir .. "/xiaozhi.so"
    mark_source("xiaozhi_app_dir", "voice_ai")
    mark_source("xz_module", "voice_ai")
  end
  if type(cfg.xz_module) == "string" and cfg.xz_module ~= "" then
    APP.config.xz_module = cfg.xz_module
    mark_source("xz_module", "voice_ai")
  end

  local xz = type(cfg.xiaozhi) == "table" and cfg.xiaozhi or {}
  if type(xz.app_dir) == "string" and xz.app_dir ~= "" then
    APP.config.xiaozhi_app_dir = xz.app_dir
    APP.config.xz_module = xz.app_dir .. "/xiaozhi.so"
    mark_source("xiaozhi_app_dir", "voice_ai")
    mark_source("xz_module", "voice_ai")
  end
  if type(xz.xz_module) == "string" and xz.xz_module ~= "" then
    APP.config.xz_module = xz.xz_module
    mark_source("xz_module", "voice_ai")
  end
  local ws = type(xz.websocket) == "table" and xz.websocket or (type(cfg.websocket) == "table" and cfg.websocket or {})
  if type(ws.url) == "string" and ws.url ~= "" then
    APP.config.xiaozhi_ws_url = ws.url
    mark_source("xiaozhi_ws_url", "voice_ai")
    if type(ws.token) == "string" then APP.config.xiaozhi_token = ws.token end
    mark_source("xiaozhi_token", "voice_ai")
  elseif type(ws.token) == "string" and ws.token ~= "" then
    APP.config.xiaozhi_token = ws.token
    mark_source("xiaozhi_token", "voice_ai")
  end
  set_config_number("xiaozhi_version", ws.version, 1, 3, "voice_ai")
  local keep_connected = xz.keep_connected
  if keep_connected == nil then keep_connected = cfg.xiaozhi_keep_connected end
  set_config_bool("xiaozhi_keep_connected", keep_connected, "voice_ai")
  set_config_number("xiaozhi_reconnect_ms", xz.reconnect_ms or cfg.xiaozhi_reconnect_ms, 1000, 60000, "voice_ai")

  local audio = type(cfg.audio) == "table" and cfg.audio or {}
  set_config_number("audio_rate", audio.rate or cfg.audio_rate, 8000, 48000, "voice_ai")
  set_config_number("audio_frame_ms", audio.frame_ms or cfg.audio_frame_ms, 20, 120, "voice_ai")
  set_config_number("audio_bits", audio.mic_bits or audio.bits or cfg.sample_bits, 16, 32, "voice_ai")
  set_config_string("audio_mic_pack", audio.mic_pack or audio.tx_mic_pack or cfg.audio_mic_pack, "voice_ai")
  set_config_number("audio_gain_shift", audio.gain_shift or audio.tx_gain_shift or cfg.audio_gain_shift, 0, 8, "voice_ai")
  set_config_number("audio_bitrate", audio.bitrate, 6000, 64000, "voice_ai")
  set_config_number("audio_complexity", audio.complexity, 0, 10, "voice_ai")
  set_config_number("audio_poll_ms", audio.poll_ms, 10, 200, "voice_ai")
  set_config_number("audio_read_wait_ms", audio.read_wait_ms, 0, 200, "voice_ai")

  local ds = type(cfg.deepseek) == "table" and cfg.deepseek or {}
  set_config_string("deepseek_base_url", ds.base_url or cfg.llm_base_url, "voice_ai")
  set_config_string("deepseek_api_key", ds.api_key or cfg.llm_api_key, "voice_ai")
  set_config_string("deepseek_model", ds.model or cfg.llm_model, "voice_ai")
  set_config_number("deepseek_timeout_ms", ds.timeout_ms or cfg.llm_timeout_ms, 5000, 120000, "voice_ai")
  set_config_number("deepseek_max_tokens", ds.max_tokens or cfg.deepseek_max_tokens, 32, 2048, "voice_ai")

  local docs = type(cfg.interface_docs) == "table" and cfg.interface_docs or {}
  set_config_bool("interface_docs_enabled", docs.enabled, "voice_ai")
  set_config_bool("interface_docs_enabled", cfg.interface_docs_enabled, "voice_ai")
  set_config_string("interface_docs_path", docs.path or cfg.interface_docs_path, "voice_ai")
  local docs_max = tonumber(docs.max_bytes or cfg.interface_docs_max_bytes)
  if docs_max then
    APP.config.interface_docs_max_bytes = clamp(docs_max, 0, 262144)
    mark_source("interface_docs_max_bytes", "voice_ai")
  end

  set_config_number("max_record_ms", cfg.max_record_ms, 1000, 30000, "voice_ai")
  set_config_number("stt_timeout_ms", cfg.stt_timeout_ms, 3000, 30000, "voice_ai")
  set_config_number("reply_limit", cfg.reply_limit, 20, 300, "voice_ai")
  if type(cfg.system_prompt) == "string" and cfg.system_prompt ~= "" and cfg.system_prompt ~= APP.LEGACY_SYSTEM_PROMPT then
    APP.config.system_prompt = cfg.system_prompt
    mark_source("system_prompt", "voice_ai")
  end
  set_config_bool("use_gif", cfg.use_gif, "voice_ai")
end

local function reset_config_defaults()
  APP.config = {
    xiaozhi_app_dir = APP.XIAOZHI_APP_DIR,
    xz_module = APP.XIAOZHI_APP_DIR .. "/xiaozhi.so",
    xiaozhi_ws_url = "",
    xiaozhi_token = "",
    xiaozhi_version = 3,
    xiaozhi_buffer_size = 8192,
    xiaozhi_timeout_ms = 10000,
    xiaozhi_keep_connected = true,
    xiaozhi_reconnect_ms = 5000,
    audio_rate = 12000,
    audio_frame_ms = 60,
    audio_bits = 32,
    audio_mic_pack = "b23",
    audio_gain_shift = 2,
    audio_bitrate = 12000,
    audio_complexity = 0,
    audio_buffer_count = 8,
    audio_poll_ms = 55,
    audio_read_wait_ms = 0,
    max_record_ms = 10000,
    stt_timeout_ms = 12000,
    deepseek_base_url = APP.DEFAULT_DEEPSEEK_BASE_URL,
    deepseek_api_key = "",
    deepseek_model = APP.DEFAULT_DEEPSEEK_MODEL,
    deepseek_timeout_ms = 35000,
    deepseek_max_tokens = 512,
    interface_docs_enabled = true,
    interface_docs_path = APP.CLAW_APP_DIR .. "/capabilities.json",
    interface_docs_max_bytes = 0,
    system_prompt = APP.DEFAULT_SYSTEM_PROMPT,
    reply_limit = 100,
    use_gif = APP.USE_GIF,
  }
  APP.config_sources = {}
end

local function load_config()
  reset_config_defaults()
  local cfg = nil
  if file and file.getcontents then
    cfg = safe_json_decode(file.getcontents(APP.APP_DIR .. "/config.json"))
  end
  preload_config_paths(cfg)
  apply_voice_config(cfg)
  load_xiaozhi_defaults()
  load_claw_llm_defaults()
end

local function style_obj(id, bg, opa, border)
  if not id then return end
  call(lv_obj_remove_style_all, id)
  call(lv_obj_set_style_bg_color, id, bg or C.bg, MAIN_STYLE)
  call(lv_obj_set_style_bg_opa, id, opa or 255, MAIN_STYLE)
  call(lv_obj_set_style_border_width, id, border and 1 or 0, MAIN_STYLE)
  if border then
    call(lv_obj_set_style_border_color, id, border, MAIN_STYLE)
    call(lv_obj_set_style_border_opa, id, 255, MAIN_STYLE)
  end
  call(lv_obj_set_style_radius, id, 0, MAIN_STYLE)
  call(lv_obj_set_style_pad_all, id, 0, MAIN_STYLE)
  if lv_obj_clear_flag and rawget(_G, "LV_OBJ_FLAG_SCROLLABLE") then
    call(lv_obj_clear_flag, id, rawget(_G, "LV_OBJ_FLAG_SCROLLABLE"))
  end
end

local function set_label_style(id, font, color, align)
  if not id then return end
  call(lv_obj_set_style_text_font, id, font or FONT_12, MAIN_STYLE)
  call(lv_obj_set_style_text_color, id, color or C.text, MAIN_STYLE)
  call(lv_obj_set_style_text_opa, id, 255, MAIN_STYLE)
  call(lv_obj_set_style_text_letter_space, id, 0, MAIN_STYLE)
  call(lv_obj_set_style_text_line_space, id, 2, MAIN_STYLE)
  if align and lv_obj_set_style_text_align then
    call(lv_obj_set_style_text_align, id, align, MAIN_STYLE)
  end
end

local function label(parent, x, y, w, h, text, font, color, align, long_mode)
  local id = lv_label_create(parent)
  call(lv_label_set_text, id, text_or(text, ""))
  call(lv_obj_set_pos, id, x, y)
  call(lv_obj_set_width, id, w)
  if h and lv_obj_set_height then call(lv_obj_set_height, id, h) end
  if lv_label_set_long_mode then
    call(lv_label_set_long_mode, id, long_mode or LABEL_LONG_CLIP)
  end
  set_label_style(id, font, color, align or ALIGN_LEFT)
  return id
end

local function set_text(id, text)
  if id then call(lv_label_set_text, id, text_or(text, "")) end
end

local function set_text_color(id, color)
  if id and lv_obj_set_style_text_color then
    call(lv_obj_set_style_text_color, id, color, MAIN_STYLE)
  end
end

local function set_opa(id, opa)
  if id and lv_obj_set_style_opa then
    call(lv_obj_set_style_opa, id, opa, MAIN_STYLE)
  end
end

local function load_font_ref(path, fallback)
  if not lv_font_load then return fallback end
  local ok, handle = pcall(function() return lv_font_load(path) end)
  if ok and type(handle) == "number" and handle > 0 then
    APP.font_handles[#APP.font_handles + 1] = handle
    return handle
  end
  return fallback
end

local function release_fonts()
  if lv_font_free then
    for _, handle in ipairs(APP.font_handles or {}) do
      pcall(function() lv_font_free(handle) end)
    end
  end
  APP.font_handles = {}
end

local function next_utf8_char(text, index)
  local b = text:byte(index)
  if not b then return nil, index end
  local len = 1
  if b >= 240 then len = 4
  elseif b >= 224 then len = 3
  elseif b >= 192 then len = 2 end
  return text:sub(index, index + len - 1), index + len
end

local function wrap_for_screen(text, max_units, max_lines)
  text = text_or(text, "")
  local lines = {}
  local line = ""
  local units = 0
  local i = 1
  while i <= #text and #lines < max_lines do
    local ch, ni = next_utf8_char(text, i)
    i = ni
    if not ch then break end
    if ch == "\r" then
    elseif ch == "\n" then
      lines[#lines + 1] = line
      line = ""
      units = 0
    else
      local b = ch:byte(1) or 0
      local add = (b < 128) and 0.55 or 1
      if units + add > max_units and line ~= "" then
        lines[#lines + 1] = line
        line = ch
        units = add
      else
        line = line .. ch
        units = units + add
      end
    end
  end
  if #lines < max_lines and line ~= "" then
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

local function short_text(text, limit)
  text = trim(text)
  limit = tonumber(limit) or 120
  if #text <= limit then return text end
  return text:sub(1, limit) .. "..."
end

local function clear_timer(name)
  local timer = APP.timers[name]
  if timer then
    pcall(function() timer:stop() end)
    pcall(function() timer:unregister() end)
    APP.timers[name] = nil
  end
end

local function single_timer(name, ms, fn)
  clear_timer(name)
  if not tmr or not tmr.create then return false end
  local timer = tmr.create()
  APP.timers[name] = timer
  timer:alarm(ms, tmr.ALARM_SINGLE, function()
    APP.timers[name] = nil
    if APP.running then fn() end
  end)
  return true
end

local function status_text()
  if S.reasoning_only then return "推理中" end
  if S.mode == "connecting" then return "连接小智" end
  if S.mode == "recording" then return "录音中" end
  if S.mode == "transcribing" then return "识别中" end
  if S.mode == "thinking" then return "DeepSeek" end
  if S.mode == "error" then return "失败" end
  if S.mode == "reply" then return "回复" end
  if APP.protocol and APP.protocol.is_audio_channel_opened and APP.protocol:is_audio_channel_opened() then
    return "已连接"
  end
  return "按下说话"
end

local function status_color()
  if S.reasoning_only then return C.yellow end
  if S.mode == "recording" then return C.red end
  if S.mode == "connecting" or S.mode == "transcribing" or S.mode == "thinking" then return C.yellow end
  if S.mode == "error" then return C.red end
  if S.mode == "reply" then return C.green end
  if APP.protocol and APP.protocol.is_audio_channel_opened and APP.protocol:is_audio_channel_opened() then
    return C.green
  end
  return C.cyan
end

local function gif_state()
  if S.reasoning_only then return "busy" end
  if S.mode == "recording" then return "attention" end
  if S.mode == "connecting" or S.mode == "transcribing" or S.mode == "thinking" then return "busy" end
  if S.mode == "error" then return "dizzy" end
  if S.mode == "reply" then return "celebrate" end
  return "idle"
end

local function gif_path_for_state(state)
  local map = {
    idle = "idle_0.gif",
    attention = "attention.gif",
    busy = "busy.gif",
    celebrate = "celebrate.gif",
    dizzy = "dizzy.gif",
    sleep = "sleep.gif",
  }
  local path = APP.APP_DIR .. "/assets/buddy/" .. (map[state] or map.idle)
  if file_exists(path) then return sd_to_lv(path) end
  return nil
end

local function update_gif()
  if not UI.gif or not lv_gif_set_src then return end
  if not APP.config.use_gif then
    if S.shown_gif_state ~= nil then
      call(lv_gif_set_src, UI.gif, nil)
      S.shown_gif_state = nil
    end
    set_opa(UI.gif, 0)
    return
  end

  local state = gif_state()
  local src = gif_path_for_state(state)
  if not src then
    set_opa(UI.gif, 0)
    return
  end
  set_opa(UI.gif, 255)
  if S.shown_gif_state ~= state then
    S.shown_gif_state = state
    call(lv_gif_set_src, UI.gif, src)
  end
end

local function update_ui()
  set_text(UI.status, status_text())
  set_text_color(UI.status, status_color())

  local body = S.reply
  if S.mode == "recording" then
    local elapsed = now_ms() - (S.record_started_ms or now_ms())
    local sec = math.floor(math.max(elapsed, 0) / 1000)
    body = "正在听\n" .. tostring(sec) .. "s\n帧 " .. tostring(S.send_frames or 0)
  elseif S.mode == "connecting" then
    body = "正在连接\n小智服务器"
  elseif S.mode == "transcribing" then
    body = "正在转文字"
  elseif S.mode == "thinking" then
    body = S.reply ~= "" and S.reply or (S.transcript ~= "" and ("听到：\n" .. S.transcript .. "\n思考中") or "思考中")
  elseif S.mode == "error" then
    body = S.last_error ~= "" and S.last_error or "服务不可用"
  end

  set_text(UI.reply, wrap_for_screen(body, 13, 6))
  update_gif()
end

local function set_mode(mode, message)
  S.mode = mode
  if message then S.reply = message end
  update_ui()
end

local function fail(message)
  S.last_error = short_text(message or "请求失败", 120)
  set_mode("error")
end

local close_ui_code

local function compile_lua_code(source, env)
  source = text_or(source, "")
  if source == "" then return nil, "empty ui_code" end
  if load then
    local ok, chunk, err = pcall(load, source, "voice_ai_ui_code", "t", env)
    if ok then return chunk, err end
  end
  if loadstring then
    local chunk, err = loadstring(source, "voice_ai_ui_code")
    if not chunk then return nil, err end
    if setfenv then setfenv(chunk, env) end
    return chunk, nil
  end
  return nil, "Lua loader missing"
end

local function make_ui_ctx(timers)
  local ctx = {
    SCREEN_W = APP.SCREEN_W,
    SCREEN_H = APP.SCREEN_H,
    MAIN = MAIN_STYLE,
    ALIGN_LEFT = ALIGN_LEFT,
    ALIGN_CENTER = rawget(_G, "LV_TEXT_ALIGN_CENTER") or 1,
    ALIGN_RIGHT = rawget(_G, "LV_TEXT_ALIGN_RIGHT") or 2,
    FONT_12 = FONT_12,
    FONT_16 = rawget(_G, "LV_FONT_MONTSERRAT_16") or FONT_12,
    FONT_20 = rawget(_G, "LV_FONT_MONTSERRAT_20") or FONT_12,
  }

  function ctx.new_screen(bg)
    local screen = lv_obj_create(nil)
    call(lv_obj_remove_style_all, screen)
    call(lv_obj_set_style_bg_color, screen, bg or C.bg, MAIN_STYLE)
    call(lv_obj_set_style_bg_opa, screen, 255, MAIN_STYLE)
    return screen
  end

  function ctx.label(parent, x, y, w, h, text, color, align, font)
    return label(parent, x or 0, y or 0, w or APP.SCREEN_W, h or 18,
      text_or(text, ""), font or APP.font_cn or FONT_12, color or C.text, align or ALIGN_LEFT, LABEL_LONG_WRAP)
  end

  function ctx.canvas(parent, x, y, w, h, bg)
    if not lv_canvas_create then return nil end
    local cvs = lv_canvas_create(parent, w or APP.SCREEN_W, h or APP.SCREEN_H, rawget(_G, "LV_IMG_CF_TRUE_COLOR"))
    call(lv_obj_set_pos, cvs, x or 0, y or 0)
    if bg ~= nil and lv_canvas_fill_bg then
      call(lv_canvas_fill_bg, cvs, bg, 255)
    end
    return cvs
  end

  function ctx.begin(cvs)
    local fn = rawget(_G, "lv_canvas_frame_begin") or rawget(_G, "lv_canvas_begin")
    if fn then return call(fn, cvs) end
    return false
  end

  function ctx.finish(cvs)
    local fn = rawget(_G, "lv_canvas_frame_end") or rawget(_G, "lv_canvas_end")
    if fn then return call(fn, cvs) end
    return false
  end

  function ctx.clear(cvs, color, opa)
    local fn = rawget(_G, "lv_canvas_fill_bg") or rawget(_G, "lv_canvas_fill")
    if fn then return call(fn, cvs, color or C.bg, opa or 255) end
    return false
  end

  function ctx.line(cvs, x1, y1, x2, y2, color, opa, width)
    if not lv_canvas_draw_line then return false end
    local ok = pcall(lv_canvas_draw_line, cvs, x1, y1, x2, y2, color or C.text, opa or 255, width or 1)
    if ok then return true end
    return call(lv_canvas_draw_line, cvs, { x1, y1, x2, y2 }, 2, {
      color = color or C.text,
      opa = opa or 255,
      width = width or 1,
    })
  end

  function ctx.rect(cvs, x, y, w, h, color, opa)
    if not lv_canvas_draw_rect then return false end
    local ok = pcall(lv_canvas_draw_rect, cvs, x, y, w, h, color or C.text, opa or 255)
    if ok then return true end
    return call(lv_canvas_draw_rect, cvs, x, y, w, h, {
      bg_color = color or C.text,
      bg_opa = opa or 255,
      radius = 0,
    })
  end

  function ctx.draw_text(cvs, x, y, w, text, color, font_size)
    if not lv_canvas_draw_text then return false end
    return call(lv_canvas_draw_text, cvs, x or 0, y or 0, w or APP.SCREEN_W,
      text_or(text, ""), { color = color or C.text, font_size = font_size or 14 })
  end

  function ctx.every(ms, fn)
    if not tmr or not tmr.create or type(fn) ~= "function" then return nil end
    local timer = tmr.create()
    timers[#timers + 1] = timer
    timer:alarm(ms or 50, tmr.ALARM_AUTO, function()
      if APP.running and APP.ui_code then pcall(fn) end
    end)
    return timer
  end

  function ctx.after(ms, fn)
    if not tmr or not tmr.create or type(fn) ~= "function" then return nil end
    local timer = tmr.create()
    timers[#timers + 1] = timer
    timer:alarm(ms or 1000, tmr.ALARM_SINGLE, function()
      if APP.running and APP.ui_code then pcall(fn) end
    end)
    return timer
  end

  function ctx.close()
    if close_ui_code then close_ui_code() end
  end

  return ctx
end

local function make_ui_env(ctx)
  local env = {
    ctx = ctx,
    math = math,
    string = string,
    table = table,
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    type = type,
    tonumber = tonumber,
    tostring = tostring,
    print = function(...)
      if print then print("[voice_ai ui_code]", ...) end
    end,
  }

  local allowed = {
    lv_obj_create = true, lv_obj_del = true, lv_obj_clean = true,
    lv_obj_set_pos = true, lv_obj_set_size = true, lv_obj_set_width = true, lv_obj_set_height = true,
    lv_obj_align = true, lv_obj_center = true, lv_obj_invalidate = true,
    lv_obj_set_style_bg_color = true, lv_obj_set_style_bg_opa = true,
    lv_obj_set_style_border_width = true, lv_obj_set_style_border_color = true,
    lv_obj_set_style_radius = true, lv_obj_set_style_pad_all = true,
    lv_obj_set_style_text_color = true, lv_obj_set_style_text_font = true,
    lv_obj_set_style_text_align = true, lv_obj_set_style_line_color = true,
    lv_obj_set_style_line_width = true, lv_obj_set_style_line_opa = true,
    lv_label_create = true, lv_label_set_text = true, lv_label_set_long_mode = true,
    lv_line_create = true, lv_line_set_points = true,
    lv_canvas_create = true, lv_canvas_frame_begin = true, lv_canvas_frame_end = true,
    lv_canvas_begin = true, lv_canvas_end = true, lv_canvas_fill = true,
    lv_canvas_fill_bg = true, lv_canvas_draw_line = true, lv_canvas_draw_rect = true,
    lv_canvas_draw_arc = true, lv_canvas_draw_text = true,
  }
  for name in pairs(allowed) do
    env[name] = rawget(_G, name)
  end
  for name, value in pairs(_G) do
    if type(name) == "string" and name:match("^LV_") then env[name] = value end
  end
  return env
end

close_ui_code = function()
  local run = APP.ui_code
  if not run then return end
  APP.ui_code = nil
  for _, timer in ipairs(run.timers or {}) do
    pcall(function() timer:stop() end)
    pcall(function() timer:unregister() end)
  end
  if type(run.cleanup) == "function" then pcall(run.cleanup) end
  if run.screen and lv_scr_load then pcall(function() lv_scr_load(APP.root or 0) end) end
  if run.screen and lv_obj_del then pcall(function() lv_obj_del(run.screen) end) end
  S.reply = "按下说话"
  S.reasoning_only = false
  set_mode("idle")
end

local function run_ui_code(source)
  close_ui_code()
  local timers = {}
  local ctx = make_ui_ctx(timers)
  local env = make_ui_env(ctx)
  local chunk, err = compile_lua_code(source, env)
  if not chunk then return false, err or "ui_code 编译失败" end
  local ok, result = pcall(chunk)
  if not ok then return false, tostring(result) end
  if type(result) == "function" then
    ok, result = pcall(result, ctx)
    if not ok then return false, tostring(result) end
  end
  if type(result) ~= "table" then
    return false, "ui_code 必须返回 { screen = screen }"
  end
  local screen = result.screen
  if not screen then return false, "ui_code 没有返回 screen" end
  APP.ui_code = {
    screen = screen,
    cleanup = result.cleanup,
    timers = timers,
  }
  if lv_scr_load then pcall(function() lv_scr_load(screen) end) end
  return true
end

local function make_xiaozhi_cfg()
  return {
    APP_DIR = APP.config.xiaozhi_app_dir,
    AUDIO = {
      rate = APP.config.audio_rate,
      channels = 1,
      frame_ms = APP.config.audio_frame_ms,
    },
    websocket = {
      url = APP.config.xiaozhi_ws_url,
      token = APP.config.xiaozhi_token,
      version = APP.config.xiaozhi_version,
      buffer_size = APP.config.xiaozhi_buffer_size,
      task_stack = 12288,
      timeout_ms = APP.config.xiaozhi_timeout_ms,
      async_send = true,
      send_task_core = 0,
      send_queue_depth = 16,
      send_queue_bytes = 65536,
      send_timeout_ms = 250,
    },
  }
end

local function close_xiaozhi_channel()
  APP.connect_goal = nil
  clear_timer("connect_timeout")
  clear_timer("keepalive_timeout")
  clear_timer("keepalive_reconnect")
  if APP.protocol then
    pcall(function() APP.protocol:send_abort_speaking("none") end)
    pcall(function() APP.protocol:send_stop_listening() end)
    pcall(function() APP.protocol:close_audio_channel(false) end)
  end
end

local function stop_audio_capture()
  clear_timer("audio")
  APP.audio_pending = ""
  if i2s and i2s.stop then
    pcall(function() i2s.stop(APP.I2S_ID) end)
  end
end

local function stop_voice()
  stop_audio_capture()
  if APP.voice and APP.voice.stop then
    pcall(function() APP.voice.stop() end)
  end
  APP.voice_ready = false
end

local function ensure_voice()
  if APP.voice_ready then return true end
  local ok, mod = pcall(require, APP.config.xz_module)
  if not ok or type(mod) ~= "table" then
    return false, "xiaozhi.so 加载失败"
  end
  APP.voice = mod.voice or rawget(_G, "voice")
  if not APP.voice or not APP.voice.start then
    return false, "voice api 缺失"
  end
  local started, ret, err = pcall(APP.voice.start, {
    rate = APP.config.audio_rate,
    channels = 1,
    frame_ms = APP.config.audio_frame_ms,
    tx = true,
    rx = true,
    hold_audio = false,
    bitrate = APP.config.audio_bitrate,
    complexity = APP.config.audio_complexity,
  })
  if not started or not ret then
    return false, tostring(err or ret or "voice.start 失败")
  end
  APP.voice_ready = true
  if APP.voice.info then
    local ok_info, info = pcall(APP.voice.info)
    if ok_info and type(info) == "table" then
      APP.frame_pcm_bytes = tonumber(info.frame_pcm_bytes) or APP.frame_pcm_bytes
    else
      APP.frame_pcm_bytes = math.floor(APP.config.audio_rate * APP.config.audio_frame_ms / 1000) * 2
    end
  else
    APP.frame_pcm_bytes = math.floor(APP.config.audio_rate * APP.config.audio_frame_ms / 1000) * 2
  end
  APP.frame_raw_bytes = APP.frame_pcm_bytes * 2
  APP.read_raw_bytes = APP.frame_raw_bytes
  return true
end

local function send_opus_frame(opus)
  if not APP.protocol or not APP.protocol:is_audio_channel_opened() then
    return false
  end
  local ok, sent = pcall(function() return APP.protocol:send_audio(opus) end)
  return ok and sent
end

local function poll_audio()
  if S.mode ~= "recording" or not APP.voice_ready then return end
  if not i2s or not i2s.read then
    stop_audio_capture()
    fail("I2S 不可用")
    return
  end
  local need = APP.read_raw_bytes - #APP.audio_pending
  if need > 0 then
    local ok, chunk = pcall(function()
      return i2s.read(APP.I2S_ID, need, APP.config.audio_read_wait_ms)
    end)
    if not ok then
      stop_audio_capture()
      fail("录音读取失败")
      return
    end
    if chunk and #chunk > 0 then
      APP.audio_pending = APP.audio_pending .. chunk
    end
  end
  if #APP.audio_pending < APP.frame_raw_bytes then return end

  local raw = APP.audio_pending:sub(1, APP.frame_raw_bytes)
  APP.audio_pending = APP.audio_pending:sub(APP.frame_raw_bytes + 1)
  if not APP.voice.encode_i2s then
    stop_audio_capture()
    fail("xiaozhi.so 缺少 encode_i2s")
    return
  end
  local ok, opus_or_err = pcall(APP.voice.encode_i2s, raw, APP.config.audio_mic_pack, APP.config.audio_gain_shift)
  if not ok or type(opus_or_err) ~= "string" then
    stop_audio_capture()
    fail(tostring(opus_or_err or "Opus 编码失败"))
    return
  end
  if send_opus_frame(opus_or_err) then
    S.send_frames = (S.send_frames or 0) + 1
  end
end

local function start_audio_capture()
  local ok_voice, err = ensure_voice()
  if not ok_voice then return false, err end
  if not i2s or not i2s.start or not i2s.read then
    return false, "I2S 不可用"
  end
  stop_audio_capture()
  APP.audio_pending = ""
  S.send_frames = 0
  local samples = math.max(160, math.floor(APP.config.audio_rate * APP.config.audio_frame_ms / 1000))
  local ok, start_err = pcall(function()
    i2s.start(APP.I2S_ID, {
      mode = i2s.MODE_MASTER | i2s.MODE_RX,
      rate = APP.config.audio_rate,
      bits = APP.config.audio_bits,
      channel = i2s.CHANNEL_ONLY_LEFT,
      format = i2s.FORMAT_I2S,
      buffer_count = APP.config.audio_buffer_count,
      buffer_len = samples,
    })
  end)
  if not ok then return false, tostring(start_err or "I2S 启动失败") end
  if not tmr or not tmr.create then
    return false, "tmr 不可用"
  end
  APP.timers.audio = tmr.create()
  APP.timers.audio:alarm(APP.config.audio_poll_ms, tmr.ALARM_AUTO, poll_audio)
  return true
end

local function extract_reply(doc)
  if type(doc) ~= "table" then return nil, "响应错误" end
  if type(doc.error) == "table" then
    return nil, text_or(doc.error.message, "DeepSeek 错误")
  end
  local function collect_content(content, parts)
    if type(content) == "string" then
      if content ~= "" then parts[#parts + 1] = content end
    elseif type(content) == "table" then
      for i = 1, #content do
        local item = content[i]
        if type(item) == "string" then
          parts[#parts + 1] = item
        elseif type(item) == "table" then
          if type(item.text) == "string" then
            parts[#parts + 1] = item.text
          elseif type(item.output_text) == "string" then
            parts[#parts + 1] = item.output_text
          elseif type(item.content) == "string" or type(item.content) == "table" then
            collect_content(item.content, parts)
          end
        end
      end
    end
  end
  local function joined(parts)
    local text = trim(table.concat(parts, "\n"))
    if text ~= "" then return text end
    return nil
  end
  local choice = type(doc.choices) == "table" and doc.choices[1] or nil
  local msg = type(choice) == "table" and choice.message or nil
  if type(msg) == "table" then
    local parts = {}
    collect_content(msg.content, parts)
    local text = joined(parts)
    if text then return text, nil end
    if type(msg.reasoning_content) == "string" and msg.reasoning_content ~= "" then
      return nil, "reasoning_only", trim(msg.reasoning_content)
    end
    if type(msg.tool_calls) == "table" then
      local tool_parts = {}
      for i = 1, #msg.tool_calls do
        local call = msg.tool_calls[i]
        local fn = type(call) == "table" and call["function"] or nil
        if type(fn) == "table" and type(fn.arguments) == "string" and fn.arguments ~= "" then
          tool_parts[#tool_parts + 1] = fn.arguments
        end
      end
      local tool_text = joined(tool_parts)
      if tool_text then return tool_text, "DeepSeek 返回了 tool_calls arguments" end
    end
  end
  if type(choice) == "table" and type(choice.text) == "string" and choice.text ~= "" then
    return trim(choice.text), nil
  end
  if type(doc.output_text) == "string" and doc.output_text ~= "" then
    return trim(doc.output_text), nil
  end
  if type(doc.output) == "table" then
    local out_parts = {}
    for i = 1, #doc.output do
      local item = doc.output[i]
      if type(item) == "table" then
        collect_content(item.content, out_parts)
        collect_content(item.text, out_parts)
      end
    end
    local out_text = joined(out_parts)
    if out_text then return out_text, nil end
  end
  return nil, "DeepSeek 没有返回文本"
end

local function looks_like_code_request(text)
  text = text_or(text, "")
  local lower = text:lower()
  return text:find("代码", 1, true)
    or text:find("编写", 1, true)
    or text:find("写一个", 1, true)
    or text:find("实现", 1, true)
    or text:find("脚本", 1, true)
    or lower:find("code", 1, true)
    or lower:find("lua", 1, true)
    or lower:find("javascript", 1, true)
    or lower:find("python", 1, true)
end

local function extract_lua_code(text)
  text = text_or(text, "")
  local code = text:match("```lua%s*\n(.-)\n```")
    or text:match("```Lua%s*\n(.-)\n```")
    or text:match("```%s*\n(.-)\n```")
  if code and trim(code) ~= "" then return trim(code) end
  local start_pos = text:find("return%s+function%s*%(")
  if start_pos then return trim(text:sub(start_pos)) end
  return nil
end

local function extract_json_object(text)
  text = text_or(text, "")
  local start_pos = text:find("{", 1, true)
  while start_pos do
    local depth = 0
    local in_string = false
    local escaped = false
    for i = start_pos, #text do
      local ch = text:sub(i, i)
      if in_string then
        if escaped then
          escaped = false
        elseif ch == "\\" then
          escaped = true
        elseif ch == '"' then
          in_string = false
        end
      else
        if ch == '"' then
          in_string = true
        elseif ch == "{" then
          depth = depth + 1
        elseif ch == "}" then
          depth = depth - 1
          if depth == 0 then
            return text:sub(start_pos, i)
          end
        end
      end
    end
    start_pos = text:find("{", start_pos + 1, true)
  end
  return nil
end

local function parse_reply_payload(text)
  text = trim(text)
  local payload = safe_json_decode(text)
  if type(payload) ~= "table" then
    local json_block = text:match("```json%s*\n(.-)\n```") or text:match("```JSON%s*\n(.-)\n```")
    if json_block then payload = safe_json_decode(json_block) end
  end
  if type(payload) ~= "table" then
    local json_text = extract_json_object(text)
    if json_text then payload = safe_json_decode(json_text) end
  end
  if type(payload) == "table" then
    local reply = type(payload.reply) == "string" and payload.reply
      or type(payload.text) == "string" and payload.text
      or type(payload.message) == "string" and payload.message
      or ""
    local ui_code = type(payload.ui_code) == "string" and payload.ui_code
      or type(payload.code) == "string" and payload.code
      or nil
    return reply ~= "" and reply or text, ui_code
  end
  return text, extract_lua_code(text)
end

local function deepseek_url()
  local base = trim(APP.config.deepseek_base_url)
  if base == "" then return "" end
  base = base:gsub("/+$", "")
  if base:match("/chat/completions$") then return base end
  return base .. "/chat/completions"
end

local function current_system_prompt()
  return table.concat({
    APP.config.system_prompt,
    "",
    "当前底层模型：" .. text_or(APP.config.deepseek_model, "unknown"),
    "当前 LLM 接口：" .. text_or(APP.config.deepseek_base_url, "unknown"),
    "当前回复上限：" .. tostring(APP.config.reply_limit) .. " 字左右。",
  }, "\n")
end

local function interface_docs_message()
  if not APP.config.interface_docs_enabled then return nil end
  local raw = read_text_file(APP.config.interface_docs_path)
  if raw == "" then return nil end
  local max_bytes = tonumber(APP.config.interface_docs_max_bytes) or 65536
  local title = "完整接口文档如下。"
  if max_bytes > 0 and #raw > max_bytes then
    raw = raw:sub(1, max_bytes) .. "\n[interface docs truncated by Voice AI safety limit]"
    title = "接口文档节选如下。"
  end
  return table.concat({
    title .. "回答代码/API/设备能力问题时必须以此为准；",
    "除非本轮真的拿到工具结果，否则只能说明如何调用，不要声称已经调用。",
    "",
    raw,
  }, "\n")
end

local schedule_xiaozhi_reconnect
local ensure_xiaozhi_connected

local function serial_log_chunks(text, max_bytes)
  if not print then return end
  text = text_or(text, "")
  max_bytes = tonumber(max_bytes) or 512
  local pos = 1
  while pos <= #text do
    local next_pos = pos
    local last_good = pos
    while next_pos <= #text do
      local _, ni = next_utf8_char(text, next_pos)
      if not ni or ni <= next_pos then break end
      if ni - pos > max_bytes and last_good > pos then break end
      last_good = ni
      next_pos = ni
      if next_pos - pos >= max_bytes then break end
    end
    if last_good <= pos then
      last_good = math.min(pos + max_bytes, #text + 1)
    end
    print(text:sub(pos, last_good - 1))
    pos = last_good
  end
end

local function serial_log_deepseek_reply(request_id, reply)
  if not print then return end
  reply = text_or(reply, "")
  print("VOICE_AI_DEEPSEEK_REPLY_BEGIN request=" .. tostring(request_id) .. " bytes=" .. tostring(#reply))
  serial_log_chunks(reply, 512)
  print("VOICE_AI_DEEPSEEK_REPLY_END request=" .. tostring(request_id))
end

local function serial_log_deepseek_body(request_id, label, body)
  if not print then return end
  body = text_or(body, "")
  label = text_or(label, "BODY")
  print("VOICE_AI_DEEPSEEK_" .. label .. "_BEGIN request=" .. tostring(request_id) .. " bytes=" .. tostring(#body))
  serial_log_chunks(body, 512)
  print("VOICE_AI_DEEPSEEK_" .. label .. "_END request=" .. tostring(request_id))
end

local function serial_log_deepseek_meta(request_id, label, detail)
  if not print then return end
  print("VOICE_AI_DEEPSEEK_" .. text_or(label, "META") .. " request=" .. tostring(request_id) .. " " .. text_or(detail, ""))
end

local function handle_deepseek_response(request_id, code, body)
  if request_id ~= APP.request_id then return end
  if code ~= 200 then
    serial_log_deepseek_body(request_id, "HTTP_BODY", body)
    fail("DeepSeek HTTP " .. tostring(code))
    return
  end
  local doc, err = safe_json_decode(body)
  if not doc then
    serial_log_deepseek_body(request_id, "BAD_JSON_BODY", body)
    fail(err or "DeepSeek 响应解析失败")
    return
  end
  local reply, reply_err, reasoning_text = extract_reply(doc)
  if not reply or reply == "" then
    if reply_err == "reasoning_only" then
      serial_log_deepseek_meta(request_id, "REASONING_ONLY", "final_content_missing")
      if reasoning_text and reasoning_text ~= "" then
        serial_log_deepseek_body(request_id, "REASONING", reasoning_text)
      end
      S.reasoning_only = true
      S.reply = "推理中\n" .. short_text(reasoning_text or "等待最终回复", APP.config.reply_limit * 4)
      set_mode("reply")
      return
    end
    serial_log_deepseek_body(request_id, "NO_REPLY_BODY", body)
    fail(reply_err or "没有回复")
    return
  end
  serial_log_deepseek_reply(request_id, reply)
  S.reasoning_only = false
  local display_reply, ui_code = parse_reply_payload(reply)
  if ui_code and ui_code ~= "" then
    serial_log_deepseek_body(request_id, "UI_CODE", ui_code)
    local ok_ui, ui_err = run_ui_code(ui_code)
    if not ok_ui then
      fail("ui_code 运行失败: " .. short_text(ui_err or "未知错误", 80))
      return
    end
    S.reply = short_text(display_reply ~= "" and display_reply or "界面已运行", APP.config.reply_limit * 4)
    set_mode("reply")
    return
  end
  if APP.request_needs_ui_code or looks_like_code_request(S.transcript) then
    serial_log_deepseek_meta(request_id, "MISSING_UI_CODE", "code_request_without_ui_code")
    fail("DeepSeek 未返回 ui_code")
    return
  end
  if APP.config.reply_limit > 0 and #display_reply > APP.config.reply_limit * 4 then
    display_reply = short_text(display_reply, APP.config.reply_limit * 4)
  end
  S.reply = display_reply
  set_mode("reply")
end

local function ask_deepseek(transcript)
  if not http or not http.post then
    fail("HTTP 不可用")
    return
  end
  local url = deepseek_url()
  if url == "" then
    fail("未配置 DeepSeek URL")
    return
  end
  if APP.config.deepseek_api_key == "" and url:find("api.deepseek.com", 1, true) then
    fail("未配置 DeepSeek key")
    return
  end
  APP.request_id = APP.request_id + 1
  local request_id = APP.request_id
  set_mode("thinking")
  clear_timer("deepseek_reasoning_only")

  local messages = {
    { role = "system", content = current_system_prompt() },
  }
  local code_request = looks_like_code_request(transcript)
  APP.request_needs_ui_code = code_request and true or false
  if code_request then
    messages[#messages + 1] = {
      role = "system",
      content = table.concat({
        "本轮用户在请求代码或屏幕效果。content 必须只返回一个 JSON 对象，不能有 Markdown、解释或代码块：",
        "{\"reply\":\"简短说明\",\"ui_code\":\"return function(ctx) ... end\"}",
        "字段名必须是 reply 和 ui_code，不能省略 ui_code。",
        "ui_code 必须是完整 Lua 源码字符串，形状必须为 return function(ctx) ... return { screen = screen, cleanup = function() end } end。",
        "用 ctx.new_screen(bg) 创建全屏 screen，用 ctx.canvas(parent,x,y,w,h,bg) 创建 canvas。",
        "Canvas 动画优先使用 ctx.begin(cvs)、ctx.clear(cvs,color)、ctx.line(cvs,x1,y1,x2,y2,color,opa,width)、ctx.rect(cvs,x,y,w,h,color,opa)、ctx.finish(cvs)、ctx.every(ms, fn)。",
        "不要调用 file/http/require/os/io/debug。不要只给思路；能画出来就直接给可运行 ui_code。",
      }, "\n"),
    }
  end
  local docs_message = interface_docs_message()
  if docs_message then
    messages[#messages + 1] = { role = "system", content = docs_message }
  end
  messages[#messages + 1] = { role = "user", content = transcript }

  local max_tokens = tonumber(APP.config.deepseek_max_tokens) or 512
  if code_request and max_tokens < 2048 then max_tokens = 2048 end

  local body = {
    model = APP.config.deepseek_model,
    messages = messages,
    stream = false,
    max_tokens = max_tokens,
  }
  if code_request then
    body.response_format = { type = "json_object" }
  end
  local raw, enc_err = safe_json_encode(body)
  if not raw then
    fail(enc_err or "请求编码失败")
    return
  end
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
  if APP.config.deepseek_api_key ~= "" then
    headers["Authorization"] = "Bearer " .. APP.config.deepseek_api_key
  end

  local ok, code, resp_body = pcall(http.post, url, {
    headers = headers,
    timeout = APP.config.deepseek_timeout_ms,
    bufsz = 98304,
  }, raw, function(cb_code, cb_body)
    handle_deepseek_response(request_id, cb_code, cb_body)
  end)
  if not ok then
    fail(tostring(code or "DeepSeek 请求失败"))
    return
  end
  if type(code) == "number" then
    handle_deepseek_response(request_id, code, resp_body)
  end
end

local function handle_transcript(text)
  text = trim(text)
  if text == "" or S.mode == "thinking" or S.mode == "reply" then return end
  clear_timer("stt_timeout")
  clear_timer("max_record")
  stop_audio_capture()
  if APP.protocol then
    pcall(function() APP.protocol:send_stop_listening() end)
    pcall(function() APP.protocol:send_abort_speaking("none") end)
  end
  S.transcript = text
  S.reply = text
  ask_deepseek(text)
end

local function begin_record_stream()
  if not APP.protocol then
    fail("小智协议未初始化")
    return false
  end
  local sent = APP.protocol:send_start_listening("manual")
  if not sent then
    fail("listen start 失败")
    close_xiaozhi_channel()
    if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("listen_start_failed") end
    return false
  end
  local ok_audio, err = start_audio_capture()
  if not ok_audio then
    fail(err)
    close_xiaozhi_channel()
    if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("audio_start_failed") end
    return false
  end
  S.record_started_ms = now_ms()
  set_mode("recording")
  single_timer("max_record", APP.config.max_record_ms, function()
    if S.mode == "recording" then
      stop_audio_capture()
      APP.protocol:send_stop_listening()
      set_mode("transcribing")
      single_timer("stt_timeout", APP.config.stt_timeout_ms, function()
        close_xiaozhi_channel()
        fail("识别超时")
        if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("stt_timeout") end
      end)
    end
  end)
  return true
end

local function ensure_protocol()
  if APP.protocol then return true end
  if APP.config.xiaozhi_ws_url == "" then
    return false, "未配置小智 websocket"
  end
  local path = APP.config.xiaozhi_app_dir .. "/protocol.lua"
  if not file_exists(path) then
    return false, "缺少小智 protocol.lua"
  end
  local ok, mod = pcall(dofile, path)
  if not ok or type(mod) ~= "table" or not mod.new then
    return false, "小智协议加载失败"
  end
  APP.ProtocolModule = mod
  APP.protocol = mod.new(make_xiaozhi_cfg())

  APP.protocol:on("opened", function()
    clear_timer("connect_timeout")
    clear_timer("keepalive_timeout")
    if S.mode == "connecting" or APP.connect_goal == "record" then
      APP.connect_goal = nil
      begin_record_stream()
    else
      APP.connect_goal = nil
      update_ui()
    end
  end)

  APP.protocol:on("closed", function()
    clear_timer("connect_timeout")
    clear_timer("keepalive_timeout")
    if S.mode == "connecting" then
      fail("小智连接已关闭")
    elseif S.mode == "recording" then
      stop_audio_capture()
      fail("小智连接中断")
    elseif S.mode == "transcribing" then
      fail("小智识别中断")
    else
      update_ui()
    end
    if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("closed") end
  end)

  APP.protocol:on("error", function(message)
    if S.mode == "connecting" or S.mode == "recording" or S.mode == "transcribing" then
      stop_audio_capture()
      fail(message)
    end
    if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("error") end
  end)

  APP.protocol:on("chat", function(role, text)
    if role == "user" then
      handle_transcript(text)
    end
  end)

  APP.protocol:on("alert", function(_, message)
    if S.mode == "connecting" or S.mode == "recording" or S.mode == "transcribing" then
      fail(message)
    end
  end)

  return true
end

local function protocol_info()
  if APP.protocol and APP.protocol.info then
    local ok, info = pcall(function() return APP.protocol:info() end)
    if ok and type(info) == "table" then return info end
  end
  return {}
end

local function protocol_is_open()
  if not APP.protocol or not APP.protocol.is_audio_channel_opened then return false end
  local ok, opened = pcall(function() return APP.protocol:is_audio_channel_opened() end)
  return ok and opened == true
end

local function protocol_is_connecting()
  return protocol_info().connecting == true
end

schedule_xiaozhi_reconnect = function()
  clear_timer("keepalive_reconnect")
  if not APP.running or not APP.config.xiaozhi_keep_connected then return end
  single_timer("keepalive_reconnect", APP.config.xiaozhi_reconnect_ms, function()
    if not APP.running or not APP.config.xiaozhi_keep_connected then return end
    if S.mode == "recording" or S.mode == "connecting" or S.mode == "transcribing" then return end
    if not protocol_is_open() and ensure_xiaozhi_connected then
      ensure_xiaozhi_connected("idle")
    end
  end)
end

ensure_xiaozhi_connected = function(goal)
  local ok_proto, err = ensure_protocol()
  if not ok_proto then return false, err end
  if goal ~= "idle" then
    APP.connect_goal = goal
  end
  if protocol_is_open() then
    if goal == "record" then
      begin_record_stream()
    else
      update_ui()
    end
    return true
  end
  if protocol_is_connecting() then return true end
  local ok = APP.protocol:open_audio_channel()
  if not ok then
    if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("open_failed") end
    return false, APP.protocol.last_error or "小智连接失败"
  end
  if goal == "record" then
    single_timer("connect_timeout", APP.config.xiaozhi_timeout_ms + 2000, function()
      close_xiaozhi_channel()
      fail("小智连接超时")
      if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("record_timeout") end
    end)
  else
    single_timer("keepalive_timeout", APP.config.xiaozhi_timeout_ms + 2000, function()
      if not protocol_is_open() and schedule_xiaozhi_reconnect then
        schedule_xiaozhi_reconnect("idle_timeout")
      end
    end)
  end
  return true
end

local function start_xiaozhi_keepalive()
  clear_timer("keepalive_reconnect")
  clear_timer("keepalive_timeout")
  if not APP.config.xiaozhi_keep_connected then return end
  if APP.config.xiaozhi_ws_url == "" then return end
  if S.mode == "recording" or S.mode == "connecting" or S.mode == "transcribing" then return end
  ensure_xiaozhi_connected("idle")
end

local function stop_recording_and_transcribe()
  if S.mode ~= "recording" then return end
  clear_timer("max_record")
  stop_audio_capture()
  if APP.protocol then
    APP.protocol:send_stop_listening()
  end
  set_mode("transcribing")
  single_timer("stt_timeout", APP.config.stt_timeout_ms, function()
    close_xiaozhi_channel()
    fail("识别超时")
    if schedule_xiaozhi_reconnect then schedule_xiaozhi_reconnect("stt_timeout") end
  end)
end

local function start_recording()
  if S.mode == "recording" or S.mode == "connecting" or S.mode == "transcribing" or S.mode == "thinking" then
    return
  end
  clear_timer("stt_timeout")
  clear_timer("max_record")
  clear_timer("connect_timeout")
  S.last_error = ""
  S.transcript = ""
  S.reply = ""
  S.reasoning_only = false
  S.send_frames = 0
  set_mode("connecting")

  local ok_conn, err = ensure_xiaozhi_connected("record")
  if not ok_conn then
    fail(err)
  end
end

local function on_short_press()
  if APP.ui_code then
    close_ui_code()
    start_recording()
  elseif S.mode == "recording" then
    stop_recording_and_transcribe()
  elseif S.mode ~= "connecting" and S.mode ~= "transcribing" and S.mode ~= "thinking" then
    start_recording()
  end
end

local function exit_app()
  APP.stop("exit")
  if app and app.exit then
    pcall(function() app.exit() end)
  end
end

local function bind_keys()
  if app and app.set_home_exit then
    pcall(function() app.set_home_exit(false) end)
  end
  if not key or not key.on then return end
  key.on(key.HOME, function(evt_type)
    if evt_type == key.SHORT then
      on_short_press()
    elseif evt_type == key.LONG_START or evt_type == key.EXIT then
      exit_app()
    end
  end)
end

local function build_ui()
  local root = lv_scr_act()
  APP.root = root
  if lv_obj_clean and lv_scr_act then lv_obj_clean(lv_scr_act()) end

  call(lv_obj_set_style_bg_color, root, C.bg, MAIN_STYLE)
  call(lv_obj_set_style_bg_opa, root, 255, MAIN_STYLE)

  if lv_gif_create then
    UI.gif = lv_gif_create(root)
    call(lv_obj_set_pos, UI.gif, 0, 42)
    call(lv_obj_set_size, UI.gif, 120, 120)
  end

  UI.line = lv_obj_create(root)
  call(lv_obj_set_pos, UI.line, 122, 20)
  call(lv_obj_set_size, UI.line, 1, 198)
  style_obj(UI.line, C.line, 255, nil)

  UI.status = label(root, 134, 32, 174, 20, "按下说话", APP.font_cn, C.cyan, ALIGN_LEFT)
  UI.reply = label(root, 134, 68, 174, 118, "短按开始", APP.font_cn, C.text, ALIGN_LEFT, LABEL_LONG_WRAP)
  UI.hint = label(root, 134, 207, 174, 16, "短按录音  再按发送", APP.font_cn, C.dim, ALIGN_LEFT)
end

local function start_timers()
  local tick = tmr and tmr.create and tmr.create() or nil
  if tick then
    APP.timers.tick = tick
    tick:alarm(250, tmr.ALARM_AUTO, function()
      if APP.running then update_ui() end
    end)
  end
end

local CONFIG_HTML = [=[
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Voice AI API 配置</title>
  <style>
    :root{--bg:#f6f8fb;--surface:#fff;--text:#0f172a;--muted:#64748b;--line:#d9e2ef;--accent:#0f766e;--accent2:#155e75;--danger:#b91c1c;--soft:#ecfeff}
    *{box-sizing:border-box}html,body{margin:0;min-height:100%}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--bg);color:var(--text);font-size:16px;line-height:1.5}
    main{width:min(960px,100%);margin:0 auto;padding:16px}.top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;margin-bottom:12px}
    h1{margin:0;font-size:26px;line-height:1.15}.sub{margin:6px 0 0;color:var(--muted)}.status{min-height:24px;color:var(--muted);font-size:14px}
    form{display:grid;gap:12px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}fieldset{border:1px solid var(--line);background:var(--surface);border-radius:8px;padding:14px;margin:0}
    legend{font-weight:750;padding:0 6px}.row{display:grid;gap:6px;margin-top:10px}label{font-weight:650;font-size:14px}input,textarea,select{width:100%;min-height:44px;border:1px solid #cbd5e1;border-radius:6px;padding:9px 10px;font:inherit;background:#fff;color:var(--text)}
    textarea{min-height:92px;resize:vertical}.hint{font-size:12px;color:var(--muted)}.source{display:inline-block;margin-left:6px;color:var(--accent2);font-size:12px;font-weight:650}
    .actions{display:flex;gap:10px;align-items:center;position:sticky;bottom:0;background:linear-gradient(180deg,rgba(246,248,251,.65),var(--bg));padding:12px 0}
    button{min-height:44px;border:0;border-radius:6px;padding:0 16px;font:inherit;font-weight:750;cursor:pointer}button.primary{background:var(--accent);color:#fff}button.secondary{background:#e2e8f0;color:#0f172a}
    button:disabled{opacity:.55;cursor:not-allowed}.pill{display:inline-block;border:1px solid var(--line);background:var(--soft);border-radius:999px;padding:4px 9px;font-size:12px;color:var(--accent2);font-weight:700}
    .error{color:var(--danger)}.ok{color:var(--accent)}@media(max-width:760px){main{padding:12px}.grid{grid-template-columns:1fr}.top{display:block}.actions{display:grid;grid-template-columns:1fr 1fr}button{width:100%}}
  </style>
</head>
<body>
<main>
  <div class="top">
    <div>
      <h1>Voice AI API 配置</h1>
      <p class="sub">优先同步 XiaoZhi 与 Lua Claw；这里保存的是 Voice AI fallback 配置。</p>
    </div>
    <div class="status" id="status" role="status" aria-live="polite">加载中</div>
  </div>
  <form id="form">
    <div class="grid">
      <fieldset>
        <legend>XiaoZhi STT <span class="source" id="src_xiaozhi_ws_url"></span></legend>
        <div class="row"><label for="xz_url">WebSocket URL</label><input id="xz_url" autocomplete="url"></div>
        <div class="row"><label for="xz_token">Token</label><input id="xz_token" type="password" autocomplete="off"></div>
        <div class="row"><label for="xz_version">Protocol Version</label><input id="xz_version" type="number" min="1" max="3" step="1"></div>
        <div class="row"><label for="xz_keep">启动后保持连接</label><select id="xz_keep"><option value="true">true</option><option value="false">false</option></select></div>
        <div class="row"><label for="xz_reconnect">断线重连 ms</label><input id="xz_reconnect" type="number" min="1000" max="60000" step="500"></div>
        <p class="hint">如果 `/sd/apps/xiaozhi/config.json` 有非空 URL，会优先使用它。</p>
      </fieldset>
      <fieldset>
        <legend>DeepSeek / LLM <span class="source" id="src_deepseek_base_url"></span></legend>
        <div class="row"><label for="ds_base">Base URL</label><input id="ds_base" autocomplete="url"></div>
        <div class="row"><label for="ds_key">API Key</label><input id="ds_key" type="password" autocomplete="off"></div>
        <div class="row"><label for="ds_model">Model</label><input id="ds_model"></div>
        <div class="row"><label for="ds_timeout">Timeout ms</label><input id="ds_timeout" type="number" min="5000" max="120000" step="1000"></div>
        <div class="row"><label for="ds_tokens">Max tokens</label><input id="ds_tokens" type="number" min="32" max="1024" step="1"></div>
        <p class="hint">如果 `/sd/apps/holocubic-lua-claw/config.json` 有 LLM 配置，会优先使用它。</p>
      </fieldset>
    </div>
    <fieldset>
      <legend>接口文档 <span class="source" id="src_interface_docs_path"></span></legend>
      <div class="grid">
        <div class="row"><label for="docs_enabled">启用</label><select id="docs_enabled"><option value="true">true</option><option value="false">false</option></select></div>
        <div class="row"><label for="docs_max">Max bytes，0 表示完整</label><input id="docs_max" type="number" min="0" max="262144" step="1024"></div>
      </div>
      <div class="row"><label for="docs_path">Path</label><input id="docs_path"></div>
    </fieldset>
    <fieldset>
      <legend>回复策略</legend>
      <div class="grid">
        <div class="row"><label for="reply_limit">回复字数上限</label><input id="reply_limit" type="number" min="20" max="300" step="1"></div>
        <div class="row"><label for="max_record">最长录音 ms</label><input id="max_record" type="number" min="1000" max="30000" step="500"></div>
      </div>
      <div class="row"><label for="system_prompt">自定义 system prompt，留空使用内置精简 prompt</label><textarea id="system_prompt"></textarea></div>
    </fieldset>
    <div class="actions">
      <button class="primary" type="submit" id="save">保存 fallback</button>
      <button class="secondary" type="button" id="reload">重新同步</button>
      <span class="pill" id="summary">同步状态未知</span>
    </div>
  </form>
</main>
<script>
const BASE="__BASE__";
const $=id=>document.getElementById(id);
function setStatus(text,bad){const el=$("status");el.textContent=text;el.className=bad?"status error":"status ok"}
function val(id,v){$(id).value=v==null?"":v}
function num(id,v){$(id).value=v==null?"":String(v)}
function src(id,s){const el=$(id); if(el) el.textContent=s?("来源 "+s):""}
async function api(path,opt){const r=await fetch(BASE+path,opt);const t=await r.text();let d={};try{d=JSON.parse(t)}catch(e){throw new Error(t||r.status)}if(!r.ok||d.ok===false)throw new Error(d.error||r.status);return d}
function fill(d){
  const c=d.config||{}, f=d.form||{}, s=d.sources||{};
  val("xz_url",f.xiaozhi?.websocket?.url ?? c.xiaozhi_ws_url);
  val("xz_token",f.xiaozhi?.websocket?.token ?? c.xiaozhi_token);
  num("xz_version",f.xiaozhi?.websocket?.version ?? c.xiaozhi_version);
  $("xz_keep").value=String(f.xiaozhi?.keep_connected ?? c.xiaozhi_keep_connected);
  num("xz_reconnect",f.xiaozhi?.reconnect_ms ?? c.xiaozhi_reconnect_ms);
  val("ds_base",f.deepseek?.base_url ?? c.deepseek_base_url);
  val("ds_key",f.deepseek?.api_key ?? c.deepseek_api_key);
  val("ds_model",f.deepseek?.model ?? c.deepseek_model);
  num("ds_timeout",f.deepseek?.timeout_ms ?? c.deepseek_timeout_ms);
  num("ds_tokens",f.deepseek?.max_tokens ?? c.deepseek_max_tokens);
  $("docs_enabled").value=String(f.interface_docs?.enabled ?? c.interface_docs_enabled);
  val("docs_path",f.interface_docs?.path ?? c.interface_docs_path);
  num("docs_max",f.interface_docs?.max_bytes ?? c.interface_docs_max_bytes);
  num("reply_limit",f.reply_limit ?? c.reply_limit);
  num("max_record",f.max_record_ms ?? c.max_record_ms);
  val("system_prompt",f.system_prompt||"");
  src("src_xiaozhi_ws_url",s.xiaozhi_ws_url);
  src("src_deepseek_base_url",s.deepseek_base_url);
  src("src_interface_docs_path",s.interface_docs_path);
  $("summary").textContent="XiaoZhi: "+(s.xiaozhi_ws_url||"default")+" / LLM: "+(s.deepseek_base_url||"default");
}
async function load(){setStatus("加载中");fill(await api("/api/config"));setStatus("已同步")}
function payload(){
  return {
    xiaozhi:{websocket:{url:$("xz_url").value.trim(),token:$("xz_token").value,version:Number($("xz_version").value)||3},keep_connected:$("xz_keep").value==="true",reconnect_ms:Number($("xz_reconnect").value)||5000},
    deepseek:{base_url:$("ds_base").value.trim(),api_key:$("ds_key").value,model:$("ds_model").value.trim(),timeout_ms:Number($("ds_timeout").value)||35000,max_tokens:Number($("ds_tokens").value)||180},
    interface_docs:{enabled:$("docs_enabled").value==="true",path:$("docs_path").value.trim(),max_bytes:Number($("docs_max").value)||0},
    reply_limit:Number($("reply_limit").value)||100,
    max_record_ms:Number($("max_record").value)||10000,
    system_prompt:$("system_prompt").value
  }
}
$("form").addEventListener("submit",async e=>{e.preventDefault();$("save").disabled=true;try{await api("/api/config",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload())});await load();setStatus("已保存 fallback")}catch(err){setStatus(err.message,true)}finally{$("save").disabled=false}});
$("reload").onclick=()=>load().catch(e=>setStatus(e.message,true));
load().catch(e=>setStatus(e.message,true));
</script>
</body>
</html>
]=]

local function response(status, content_type, body)
  return {
    status = status or "200 OK",
    type = content_type or "text/plain; charset=utf-8",
    headers = {
      ["cache-control"] = "no-store",
      ["access-control-allow-origin"] = "*",
      ["connection"] = "close",
    },
    body = body or "",
  }
end

local function json_response(status, value)
  local raw, err = safe_json_encode(value)
  if not raw then
    status = "500 Internal Server Error"
    raw = "{\"ok\":false,\"error\":\"" .. json_escape(err or "json encode failed") .. "\"}"
  end
  return response(status or "200 OK", "application/json; charset=utf-8", raw)
end

local function read_request_body(req, max_bytes)
  if not req or not req.getbody then return "", nil end
  local parts = {}
  local total = 0
  while true do
    local chunk = req.getbody()
    if not chunk then break end
    total = total + #chunk
    if max_bytes and total > max_bytes then
      return nil, "body too large"
    end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts), nil
end

local function own_config_doc()
  local doc = safe_json_decode(read_text_file(APP.APP_DIR .. "/config.json"))
  return type(doc) == "table" and doc or {}
end

local function config_snapshot()
  local own = own_config_doc()
  return {
    ok = true,
    version = APP.VERSION,
    route_base = APP.route_base,
    config_path = APP.APP_DIR .. "/config.json",
    sync_priority = { "xiaozhi", "holocubic-lua-claw", "voice_ai", "defaults" },
    sources = APP.config_sources or {},
    config = APP.config,
    form = own,
  }
end

local function write_text_file(path, data)
  if file and file.putcontents then
    local ok, ret = pcall(function() return file.putcontents(path, data) end)
    if ok and ret ~= false then return true end
  end
  if not file or not file.open then return false, "file api missing" end
  local fd = file.open(path, "w+")
  if not fd then return false, "open failed" end
  local ok, err = pcall(function() return fd:write(data or "") end)
  fd:close()
  if not ok then return false, tostring(err) end
  return true
end

local function save_config_doc(doc)
  if type(doc) ~= "table" then
    return false, "json root must be object"
  end
  local clean = {
    xiaozhi = type(doc.xiaozhi) == "table" and doc.xiaozhi or nil,
    deepseek = type(doc.deepseek) == "table" and doc.deepseek or nil,
    interface_docs = type(doc.interface_docs) == "table" and doc.interface_docs or nil,
    system_prompt = type(doc.system_prompt) == "string" and doc.system_prompt or "",
    max_record_ms = tonumber(doc.max_record_ms) or APP.config.max_record_ms,
    stt_timeout_ms = tonumber(doc.stt_timeout_ms) or APP.config.stt_timeout_ms,
    reply_limit = tonumber(doc.reply_limit) or APP.config.reply_limit,
    use_gif = type(doc.use_gif) == "boolean" and doc.use_gif or APP.config.use_gif,
  }
  local raw, err = safe_json_encode(clean)
  if not raw then return false, err end
  return write_text_file(APP.APP_DIR .. "/config.json", raw)
end

local function route_config_get()
  load_config()
  return json_response("200 OK", config_snapshot())
end

local function route_config_post(req)
  local body, read_err = read_request_body(req, 32768)
  if not body then
    return json_response("400 Bad Request", { ok = false, error = read_err or "body read failed" })
  end
  local doc, dec_err = safe_json_decode(body)
  if not doc then
    return json_response("400 Bad Request", { ok = false, error = dec_err or "json decode failed" })
  end
  local ok, err = save_config_doc(doc)
  if not ok then
    return json_response("500 Internal Server Error", { ok = false, error = err or "save failed" })
  end
  close_xiaozhi_channel()
  stop_voice()
  if APP.protocol then
    pcall(function() APP.protocol:stop() end)
    APP.protocol = nil
  end
  load_config()
  update_ui()
  start_xiaozhi_keepalive()
  return json_response("200 OK", config_snapshot())
end

local function route_config_page()
  local html = CONFIG_HTML:gsub("__BASE__", APP.route_base)
  return response("200 OK", "text/html; charset=utf-8", html)
end

local function register_route(method, route, handler)
  if not httpd or not httpd.dynamic then return false end
  local ok, err = pcall(function()
    local e = httpd.dynamic(method, route, handler)
    if e then error(e) end
  end)
  if ok then
    APP.routes[#APP.routes + 1] = { method = method, route = route }
    return true
  end
  S.last_error = "web route failed: " .. tostring(err)
  return false
end

local function register_web_routes_for_base(base)
  if not base or base == "" then return end
  register_route(httpd.GET, base, route_config_page)
  register_route(httpd.GET, base .. "/", route_config_page)
  register_route(httpd.GET, base .. "/api/config", route_config_get)
  register_route(httpd.POST, base .. "/api/config", route_config_post)
end

local function start_web()
  if not httpd or not httpd.start or not httpd.dynamic then return end
  pcall(function()
    httpd.start({
      webroot = "/sd",
      auto_index = httpd.INDEX_NONE,
      max_handlers = APP.WEB_MAX_HANDLERS,
    })
  end)
  register_web_routes_for_base(APP.route_base)
  if APP.route_base ~= "/voice_ai" then
    register_web_routes_for_base("/voice_ai")
  end
end

local function unregister_web_routes()
  if not httpd or not httpd.unregister then
    APP.routes = {}
    return
  end
  for i = #APP.routes, 1, -1 do
    local item = APP.routes[i]
    pcall(function() httpd.unregister(item.method, item.route) end)
  end
  APP.routes = {}
end

function APP.stop()
  APP.running = false
  APP.request_id = APP.request_id + 1
  unregister_web_routes()
  close_ui_code()
  close_xiaozhi_channel()
  stop_voice()
  for _, timer in pairs(APP.timers or {}) do
    pcall(function()
      timer:stop()
      timer:unregister()
    end)
  end
  APP.timers = {}
  if APP.protocol then
    pcall(function() APP.protocol:stop() end)
    APP.protocol = nil
  end
  if key and key.off then
    pcall(key.off, key.HOME)
  end
  if app and app.set_home_exit then
    pcall(function() app.set_home_exit(true) end)
  end
  if UI.gif and lv_gif_set_src then
    pcall(lv_gif_set_src, UI.gif, nil)
  end
  release_fonts()
end

load_config()
APP.font_cn = load_font_ref(APP.APP_DIR .. "/font/msyh_cn_13.bin", FONT_12)
build_ui()
bind_keys()
start_timers()
start_web()
update_ui()
start_xiaozhi_keepalive()
