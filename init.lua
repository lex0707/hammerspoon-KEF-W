-- KEF LS50W2 menubar slider (glass), redesigned controls

local SPEAKER_IP   = "192.168.1.109"
local POLL_SECONDS = 5
local STEP         = 2

local http   = require("hs.http")
local json   = require("hs.json")
local image  = require("hs.image")
local scr    = require("hs.screen")
local timer  = require("hs.timer")
local canvas = require("hs.canvas")

local kefPos = hs.settings.get('kef.pos')
local dragTap
local dismissTap
local autoCloseTimer
local autoCloseLocked = false

local PATH_SOURCE = "settings:/kef/play/physicalSource"   -- returns kefPhysicalSource
local PATH_NOW    = "player:player/data"                  -- rich state/metadata container (includes state; artist/title when available)

--[[
Additional KEF API paths worth exploring when expanding controls:
  * "player:power" (role `value`) – exposes on/off state and allows toggling power.
  * "settings:/network/info" – network summary including IP address, SSID, and link type.
  * "settings:/network/wifi" – Wi-Fi specific details such as SSID/BSSID and signal strength.
  * "settings:/network/ethernet" – reports whether a wired backhaul is active.
  * "player:status" – high level player state (playing, paused, standby, etc.).
]]

local function kefGetNowPlaying(cb)
  if not PATH_NOW then if cb then cb(nil) end return end
  local url = ("http://%s/api/getData?path=%s&roles=%%40all"):format(SPEAKER_IP, PATH_NOW)
  http.asyncGet(url, nil, function(status, body)
    local line
    if status == 200 and body then
      -- Try rich metadata first (if PATH_NOW later points to .../data)
      local title  = body:match('"title"%s*:%s*"([^"]+)"') or body:match('"track"%s*:%s*"([^"]+)"')
      local artist = body:match('"artist"%s*:%s*"([^"]+)"') or body:match('"artistName"%s*:%s*"([^"]+)"')
      if not title  then title  = body:match('"value"%s*:%s*{[^}]*"title"%s*:%s*"([^"]+)"')  end
      if not artist then artist = body:match('"value"%s*:%s*{[^}]*"artist"%s*:%s*"([^"]+)"') end
      if title and artist then
        line = artist .. " — " .. title
      elseif title then
        line = title
      else
        -- Fallback to simple player state (our PATH_NOW currently points to .../state)
        local state = body:match('"state"%s*:%s*"([^"]+)"')
        if state then line = "State: " .. state end
      end
    end
    if cb then cb(line) end
  end)
end

local function kefGetInput(cb)
  if not PATH_SOURCE then if cb then cb(nil) end return end
  local url = ("http://%s/api/getData?path=%s&roles=%%40all"):format(SPEAKER_IP, PATH_SOURCE)
  http.asyncGet(url, nil, function(status, body)
    local name
    if status == 200 and body then
      local srcId = body:match('"str"%s*:%s*"([^"]+)"')
      local title = body:match('"title"%s*:%s*"([^"]+)"')
      local valueStr = body:match('"value"%s*:%s*{[^}]*"str"%s*:%s*"([^"]+)"')
      if not srcId and valueStr then srcId = valueStr end
      local nameStr = body:match('"name"%s*:%s*"([^"]+)"')
      if not title and nameStr then title = nameStr end
      local phys = body:match('"kefPhysicalSource"%s*:%s*"([^"]+)"')
      if phys and phys ~= '' then
        srcId = phys
      end
      name = srcId or title
    end
    if cb then cb(name) end
  end)
end

kefSetSource = function(src)
  -- Map UI labels to KEF physical source identifiers
  local map = { wifi = "wifi", bt = "bluetooth", optical = "optical", hdmi = "hdmi", tv = "tv" }
  local target = map[(src or ""):lower()] or src
  if not target or target == "" then return end
  local body = json.encode({
    path = PATH_SOURCE,
    role = "value",
    value = { type = "kefPhysicalSource", kefPhysicalSource = target }
  })
  http.asyncPost(("http://%s/api/setData"):format(SPEAKER_IP), body, { ["Content-Type"] = "application/json" }, function() end)
end

local function dismissPopover()
  if _G.kefWV and _G.kefWV:hswindow() then
    _G.kefWV:delete()
    _G.kefWV = nil
  end
  if dragTap then
    dragTap:stop()
    dragTap = nil
  end
  if dismissTap then
    dismissTap:stop()
    dismissTap = nil
  end
  if autoCloseTimer then
    autoCloseTimer:stop()
    autoCloseTimer = nil
  end
  autoCloseLocked = false
  _G.__kefDragOffset = nil
end

local function armAutoClose(seconds, opts)
  opts = opts or {}
  local force = opts.force or false
  if autoCloseLocked and not force then
    return
  end
  if autoCloseTimer then
    autoCloseTimer:stop()
    autoCloseTimer = nil
  end
  if seconds and seconds > 0 then
    if force then autoCloseLocked = true end
    autoCloseTimer = timer.doAfter(seconds, function()
      autoCloseTimer = nil
      autoCloseLocked = false
      dismissPopover()
    end)
  else
    autoCloseLocked = false
  end
end

kefRefresh = function()
  kefGetVol(function(v)
    if v then
      currentVol = v
      if _G.kefWV then _G.kefWV:evaluateJavaScript("setStatus('Online')") end
    else
      if _G.kefWV then _G.kefWV:evaluateJavaScript("setStatus('Offline')") end
    end
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d,true)"):format(currentVol or 0)) end
  end)
  kefGetInput(function(name)
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setInput('%s')"):format(name or "")) end
  end)
  kefGetNowPlaying(function(txt)
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setNow('%s')"):format(((txt or ""):gsub("[\\']", "\\%0")))) end
  end)
  if _G.kefWV then armAutoClose(15) end
end

-- ---------- KEF HTTP helpers ----------
function kefGetVol(cb)  -- async
  local url = ("http://%s/api/getData?path=player:volume&roles=value"):format(SPEAKER_IP)
  http.asyncGet(url, nil, function(status, body)
    local v
    if status == 200 and body then
      v = tonumber((body:match('"i32_"%s*:%s*(%d+)')))
    end
    if cb then cb(v) end
  end)
end

function kefGetVolSync()  -- sync for first seed
  local url = ("http://%s/api/getData?path=player:volume&roles=value"):format(SPEAKER_IP)
  local status, body = http.get(url)
  if status == 200 and body then
    return tonumber((body:match('"i32_"%s*:%s*(%d+)')))
  end
  return nil
end

function kefSetVol(v, cb)
  if v < 0 then v = 0 end
  if v > 100 then v = 100 end
  local body = json.encode({ path="player:volume", role="value", value={ type="i32_", i32_=v }})
  http.asyncPost(("http://%s/api/setData"):format(SPEAKER_IP), body,
                 {["Content-Type"]="application/json"},
                 function()
                   if _G.kefWV then armAutoClose(15) end
                   if cb then cb(v) end
                 end)
end

local menu = hs.menubar.new()
do
  local symbol = image.imageFromName("hifispeaker.fill")
  if symbol then
    local iconCanvas = canvas.new({ x = 0, y = 0, w = 24, h = 24 })
    iconCanvas[1] = {
      type = "circle",
      action = "fill",
      fillColor = { hex = "#3c3c3e", alpha = 1 },
      radius = 12,
      center = { x = "50%", y = "50%" }
    }
    iconCanvas[2] = {
      type = "image",
      image = symbol,
      tintColor = { red = 1, green = 0.2, blue = 0.2, alpha = 1 },
      frame = { x = 3, y = 3, w = 18, h = 18 },
      imageScaling = "scaleProportionallyDown"
    }
    local iconImage = iconCanvas:imageFromCanvas()
    menu:setIcon(iconImage, false)
    iconCanvas:delete()
  else
    local fallback = image.imageFromName("speaker.wave.3.fill")
    if fallback then menu:setIcon(fallback, true) else menu:setTitle("KEF") end
  end
end

-- ---------- State ----------
local currentVol = kefGetVolSync() or 0  -- seed synchronously so we never start at 0
local initVol = currentVol or 0

local sliderSymbolData
do
  local sliderSymbol = image.imageFromName("hifispeaker.fill")
  if sliderSymbol then
    sliderSymbolData = sliderSymbol:encodeAsURLString()
  end
end

local sliderKnobMarkup = ''
if sliderSymbolData then
  sliderKnobMarkup = string.format('<img src="%s" alt="" role="presentation">', sliderSymbolData)
end

local html = string.format([[
<!doctype html><meta charset="utf-8">
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  html { height:100%%; background: transparent; }
  body { height:100%%; }
  body {
    margin: 0;
    background: rgba(0,0,0,0);
    font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display:flex;
    align-items:center;
    justify-content:center;
    color: #fff;
  }
  .glass {
    position: relative;
    display:flex;
    flex-direction:column;
    gap:20px;
    padding:30px 32px 34px; width: 360px;
    border-radius:42px;
    overflow:hidden;
    background: linear-gradient(160deg, rgba(255,60,92,0.82), rgba(155,0,26,0.7));
    border:1px solid rgba(255,255,255,0.28);
    box-shadow: 0 32px 72px rgba(0,0,0,0.58), 0 16px 36px rgba(120,0,24,0.38);
    backdrop-filter: saturate(240%%) blur(55px);
    -webkit-backdrop-filter: saturate(240%%) blur(55px);
  }
  .glass::before {
    content:""; position:absolute; inset:-8%%;
    border-radius:48px;
    background:
      radial-gradient(circle at 18%% 18%%, rgba(255,255,255,0.6), rgba(255,255,255,0) 52%%),
      linear-gradient(140deg, rgba(255,190,204,0.6), rgba(255,60,80,0.28) 45%%, rgba(70,0,16,0.32) 100%%);
    mix-blend-mode: screen; opacity:0.85; pointer-events:none;
  }
  .glass::after {
    content:""; position:absolute; inset:0;
    border-radius:inherit;
    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.16), inset 0 18px 48px rgba(255,255,255,0.12);
    pointer-events:none;
  }
  @media (prefers-color-scheme: dark) {
    .glass {
      background: linear-gradient(160deg, rgba(214,18,46,0.78), rgba(120,0,24,0.64));
      border-color: rgba(255,255,255,0.22);
      box-shadow: 0 36px 84px rgba(0,0,0,0.72), 0 16px 42px rgba(90,0,20,0.45);
    }
    .glass::before {
      opacity:0.78;
    }
  }
  .glass > * { position: relative; z-index: 1; }
  .header { display:flex; align-items:center; justify-content:space-between; gap:16px; padding-bottom:4px; }
  .title { display:flex; flex-direction:column; gap:2px; letter-spacing: 1.6px; text-transform: uppercase; font-weight:600; font-size:12px; }
  .close {
    width: 22px; height: 22px; border-radius: 50%%;
    border: none; background: radial-gradient(circle at 35%% 35%%, rgba(255,255,255,0.9), rgba(255,255,255,0.55));
    position: relative; cursor: pointer; flex-shrink: 0;
    box-shadow: 0 6px 18px rgba(0,0,0,0.3);
    transition: transform .2s ease, opacity .2s ease;
  }
  .close::before, .close::after {
    content: ""; position: absolute; top:50%%; left:50%%;
    width: 10px; height: 2px; background: rgba(60,0,0,0.8);
    border-radius: 999px;
  }
  .close::before { transform: translate(-50%%,-50%%) rotate(45deg); }
  .close::after  { transform: translate(-50%%,-50%%) rotate(-45deg); }
  .close:hover { transform: scale(1.06); }
  .close:focus-visible { outline: 2px solid rgba(255,255,255,0.8); outline-offset: 2px; }
  .close.closing { opacity:0.65; }
  .row { display:flex; align-items:center; gap:12px; }
  .slider-wrap { position: relative; flex: 1; height:48px; display:flex; align-items:center; }
  .slider-track {
    position:absolute; left:4px; right:4px; height:10px; border-radius:999px;
    background: rgba(255,255,255,0.16); overflow:hidden;
  }
  .slider-track::after {
    content:""; position:absolute; inset:0;
    width: var(--fill, 0%%);
    background: linear-gradient(135deg, rgba(255,255,255,0.8), rgba(255,180,180,0.58));
    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.2);
  }
  input[type=range]{
    -webkit-appearance: none;
    width: 100%%; height: 48px;
    background: transparent;
    outline: none;
    position: relative; z-index: 2;
    cursor: pointer;
  }
  input[type=range]::-webkit-slider-runnable-track{
    height: 10px; background: transparent;
  }
  input[type=range]::-webkit-slider-thumb{
    -webkit-appearance: none;
    width: 0; height: 0; border: 0; box-shadow:none; background: transparent;
  }
  .speaker-knob {
    position:absolute; top:50%%; left:0%%;
    width:34px; height:34px; border-radius:50%%;
    background: rgba(255,255,255,0.24);
    box-shadow: 0 10px 26px rgba(0,0,0,0.38), inset 0 1px 0 rgba(255,255,255,0.38);
    display:flex; align-items:center; justify-content:center;
    transform: translate(-50%%,-50%%);
    pointer-events:none; transition: background .2s ease, box-shadow .2s ease;
    backdrop-filter: saturate(200%%) blur(18px);
    -webkit-backdrop-filter: saturate(200%%) blur(18px);
  }
  .speaker-knob img { width: 18px; height: 18px; filter: drop-shadow(0 2px 6px rgba(0,0,0,0.4)); }
  .speaker-knob.bounce { animation: bounce 0.45s ease-out; }
  @keyframes bounce {
    0%% { transform: translate(-50%%,-50%%) scale(1); }
    35%% { transform: translate(-50%%,-68%%) scale(1.08); }
    65%% { transform: translate(-50%%,-46%%) scale(0.95); }
    100%% { transform: translate(-50%%,-50%%) scale(1); }
  }
  #val { min-width: 44px; text-align: right; font-variant-numeric: tabular-nums; opacity: 0; transition: opacity .2s ease; font-size: 12px; }
  .mutebtn {
    width: 46px; height: 46px; border-radius: 18px;
    border: 1px solid rgba(255,255,255,0.36);
    background: rgba(255,255,255,0.18); color:#fff; cursor: pointer;
    display:flex; align-items:center; justify-content:center;
    transition: background .18s ease, border-color .18s ease, box-shadow .18s ease;
    box-shadow: 0 10px 24px rgba(0,0,0,0.32);
    backdrop-filter: saturate(180%%) blur(14px);
    -webkit-backdrop-filter: saturate(180%%) blur(14px);
  }
  .mutebtn:hover { background: linear-gradient(150deg, rgba(255,230,160,0.32), rgba(0,255,255,0.28)); border-color: rgba(255,255,255,0.52); box-shadow: 0 14px 30px rgba(0,0,0,0.32); }
  .mutebtn svg { width: 20px; height: 20px; }
  .mutebtn:focus-visible { outline: 2px solid rgba(255,255,255,0.8); outline-offset: 2px; }
  .meta { font-size:12px; opacity:.9; display:flex; flex-direction:column; gap:4px; }
  .meta span { display:flex; align-items:center; gap:8px; }
  .label { opacity:0.68; text-transform: uppercase; letter-spacing: 1.4px; font-size:10px; }
  .inputs { display:grid; grid-template-columns: repeat(6, 1fr); gap:10px; }
  .inputs button {
    width: 46px; height: 46px; border-radius: 18px;
    border: 1px solid rgba(255,255,255,0.32); background: rgba(255,255,255,0.18); color:#fff; cursor:pointer;
    display:flex; align-items:center; justify-content:center;
    transition: transform .16s ease, background .2s ease, border-color .2s ease, box-shadow .2s ease;
    backdrop-filter: saturate(180%%) blur(16px);
    -webkit-backdrop-filter: saturate(180%%) blur(16px);
    box-shadow: 0 10px 24px rgba(0,0,0,0.3);
  }
  .inputs button svg { width: 22px; height: 22px; fill: #fff; transition: fill .2s ease; }
  .inputs button:hover { background: linear-gradient(150deg, rgba(255,220,120,0.35), rgba(0,255,255,0.26)); border-color: rgba(255,255,255,0.6); box-shadow: 0 14px 32px rgba(0,0,0,0.32); transform: translateY(-1px); }
  .inputs button.active { background: rgba(255,255,255,0.9); border-color: rgba(255,255,255,0.9); box-shadow: 0 12px 30px rgba(255,64,64,0.48); }
  .inputs button.active svg { fill: #8b0000; }
  .inputs button:focus-visible { outline: 2px solid rgba(255,255,255,0.8); outline-offset: 2px; }
  .sr { position:absolute; width:1px; height:1px; padding:0; margin:-1px; overflow:hidden; clip:rect(0,0,0,0); border:0; }
  .now { font-size:12px; opacity:.92; margin-top:4px; line-height:1.45; }
  ::-webkit-scrollbar { width:0; height:0; }
</style>
<div class="glass">
  <div class="header" data-drag-handle>
    <div class="title">
      <span>WIRELESS</span>
      <span>KEF W</span>
    </div>
    <button class="close" id="close" aria-label="Close"></button>
  </div>
  <div class="row">
    <div class="slider-wrap">
      <div class="slider-track"></div>
      <input id="slider" type="range" min="0" max="100" value="%d">
      <div class="speaker-knob">%s</div>
    </div>
    <div id="val">%d%%</div>
    <button id="mute" class="mutebtn" aria-label="Mute">
      <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5 9v6h3l4 4V5L8 9H5zm12.54 3 1.23-1.23-1.06-1.06L16.47 11l-1.24-1.29-1.06 1.06L15.4 12l-1.23 1.23 1.06 1.06L16.47 13l1.24 1.29 1.06-1.06L17.54 12z" fill="currentColor"/></svg>
    </button>
  </div>
  <div class="meta">
    <span><span class="label">Status</span><span id="status">—</span></span>
    <span><span class="label">Input</span><span id="input">—</span></span>
  </div>
  <div class="now" id="now">Now Playing: —</div>
  <div class="inputs">
    <button data-src="wifi" id="wifi" aria-label="Wi-Fi">
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12 18a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zm0-3.6a4.6 4.6 0 0 1 3.27 1.35l-1.12 1.11A3 3 0 0 0 12 15.9a3 3 0 0 0-2.15.94l-1.12-1.12A4.6 4.6 0 0 1 12 14.4zm0-4.2a8.8 8.8 0 0 1 6.22 2.58l-1.1 1.1A7.2 7.2 0 0 0 12 12a7.2 7.2 0 0 0-5.12 2.07l-1.1-1.1A8.8 8.8 0 0 1 12 10.2zm0-4.2c3.35 0 6.45 1.3 8.8 3.66l-1.1 1.1A11 11 0 0 0 12 8a11 11 0 0 0-7.7 3.17l-1.1-1.1A12.6 12.6 0 0 1 12 6z"/></svg>
      <span class="sr">Wi-Fi</span>
    </button>
    <button data-src="bt" id="bt" aria-label="Bluetooth">
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12.5 3.5v6.09L9.35 6.44 8.3 7.5l4.04 4.04L8.3 15.57l1.05 1.06 3.15-3.15v6.09l4.9-4.9-3.41-3.41 3.41-3.41-4.9-4.9zm1.4 3.55 1.16 1.16-1.16 1.16V7.05zm0 6.58 1.16 1.16-1.16 1.16v-2.32z"/></svg>
      <span class="sr">Bluetooth</span>
    </button>
    <button data-src="optical" id="optical" aria-label="Optical">
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12 4a8 8 0 1 0 0 16A8 8 0 0 0 12 4zm0 2.2a5.8 5.8 0 1 1 0 11.6 5.8 5.8 0 0 1 0-11.6zm0 2.3a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z"/></svg>
      <span class="sr">Optical</span>
    </button>
    <button data-src="tv" id="tv" aria-label="TV">
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M5 5h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-4.5l1.8 2.2h-1.8l-1.7-2.2H9.2l-1.7 2.2H5.7l1.8-2.2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2zm0 2v8h14V7H5z"/></svg>
      <span class="sr">TV</span>
    </button>
    <button data-src="hdmi" id="hdmi" aria-label="HDMI">
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M4 9h16v6H4V9zm2 2v2h2v-2H6zm4 0v2h4v-2h-4zm6 0v2h2v-2h-2z"/></svg>
      <span class="sr">HDMI</span>
    </button>
    <button id="refresh" aria-label="Refresh">
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M12 5a7 7 0 1 1-6.93 8h2.04A5 5 0 1 0 12 7V4l4 4-4 4V9a5 5 0 1 0 0 10 5 5 0 0 0 4.9-6h2.02A7 7 0 0 1 12 5z"/></svg>
      <span class="sr">Refresh</span>
    </button>
  </div>
</div>
<script>
  const glass = document.querySelector('.glass');
  const s = document.getElementById('slider');
  const track = document.querySelector('.slider-track');
  const knob = document.querySelector('.speaker-knob');
  const v = document.getElementById('val');
  const m = document.getElementById('mute');
  const st = document.getElementById('status');
  const inp = document.getElementById('input');
  const now = document.getElementById('now');
  const closeBtn = document.getElementById('close');
  let hideTimer = null, dragging=false, pingLock=false;

  function send(msg){
    try{ window.webkit.messageHandlers.kef.postMessage(msg); }catch(e){}
  }

  function pingInteraction(){
    if (pingLock) return;
    pingLock = true;
    send({action:'interaction'});
    setTimeout(()=>{ pingLock = false; }, 1200);
  }

  function showTemp(n){
    v.textContent = (Math.round(n)||0) + '%%';
    v.style.opacity = 1;
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(()=>{ v.style.opacity = 0; }, 1200);
    pingInteraction();
  }

  function updateSliderVisuals(val){
    const min = parseFloat(s.min) || 0;
    const max = parseFloat(s.max) || 100;
    const value = Math.min(max, Math.max(min, Number(val) || 0));
    const span = (max - min) || 1;
    const pct = ((value - min) / span) * 100;
    if (track) track.style.setProperty('--fill', pct + '%%');
    if (knob) knob.style.left = pct + '%%';
  }

  function triggerBounce(){
    if (!knob) return;
    knob.classList.remove('bounce');
    void knob.offsetWidth;
    knob.classList.add('bounce');
  }

  function setVol(n, quiet){
    if (dragging && !quiet) return;
    s.value = n;
    updateSliderVisuals(n);
    if (!quiet) {
      showTemp(n);
      triggerBounce();
    }
  }

  function beginDrag(){ dragging=true; pingInteraction(); }
  function endDrag(){ dragging=false; }

  s.addEventListener('pointerdown', beginDrag, {passive:true});
  window.addEventListener('pointerup', endDrag, {passive:true});
  s.addEventListener('mousedown', beginDrag, {passive:true});
  window.addEventListener('mouseup', endDrag, {passive:true});
  s.addEventListener('touchstart', beginDrag, {passive:true});
  window.addEventListener('touchend', endDrag, {passive:true});

  s.addEventListener('input', ()=> { showTemp(s.value); updateSliderVisuals(s.value); });
  s.addEventListener('change', ()=> {
    const value = parseInt(s.value, 10);
    send({action:'setVol', vol: value});
    triggerBounce();
  });

  m.addEventListener('click', ()=> {
    send({action:'setVol', vol:0});
    showTemp(0);
    triggerBounce();
  });

  closeBtn.addEventListener('click', ()=> {
    const delay = 5;
    closeBtn.classList.add('closing');
    send({action:'close', delay, lock:true});
    setTimeout(()=> closeBtn.classList.remove('closing'), delay * 1000);
  });

  const labelMap = {
    wifi: 'Wi\u2011Fi',
    'wi-fi': 'Wi\u2011Fi',
    wireless: 'Wi\u2011Fi',
    airplay: 'AirPlay',
    bluetooth: 'Bluetooth',
    bt: 'Bluetooth',
    optical: 'Optical',
    toslink: 'Optical',
    tv: 'TV',
    hdmi: 'TV',
    hdmi1: 'TV',
    hdmi2: 'TV',
    earc: 'TV',
    arc: 'TV',
    coaxial: 'Coaxial',
    coax: 'Coaxial',
    usb: 'USB',
    'usb-dac': 'USB DAC',
    analog: 'Analog',
    aux: 'Analog'
  };

  function setActive(name){
    const norm = (name||'').toLowerCase();
    const alias = (() => {
      if (!norm) return [];
      if (norm.includes('tv') || norm.includes('hdmi') || norm.includes('arc')) return ['hdmi','tv'];
      if (norm.includes('bluetooth')) return ['bt'];
      if (norm.includes('wifi') || norm.includes('wireless')) return ['wifi'];
      if (norm.includes('optical') || norm.includes('toslink')) return ['optical'];
      return [norm];
    })();
    document.querySelectorAll('.inputs button[data-src]').forEach(b=>{
      const id = (b.dataset.src||'').toLowerCase();
      if (alias.includes(id)) b.classList.add('active'); else b.classList.remove('active');
    });
  }

  window.setInput = function(name){
    const norm = (name||'').toLowerCase();
    setActive(norm);
    let label = labelMap[norm];
    if (!label) {
      if (norm.includes('hdmi') || norm.includes('earc') || norm.includes('arc') || norm.includes('tv')) {
        label = 'TV';
      } else if (norm.includes('wifi') || norm.includes('wireless')) {
        label = 'Wi\u2011Fi';
      } else if (norm.includes('bluetooth') || norm === 'bt') {
        label = 'Bluetooth';
      } else if (norm.includes('optical') || norm.includes('toslink')) {
        label = 'Optical';
      } else if (norm.includes('coax')) {
        label = 'Coaxial';
      } else if (norm.includes('usb')) {
        label = 'USB';
      }
    }
    if (!label && norm) label = name;
    if (!label) label = '\u2014';
    inp.textContent = label;
  }

  window.setNow = function(txt){ now.textContent = 'Now Playing: ' + (txt||'\u2014'); }

  document.querySelectorAll('.inputs button[data-src]').forEach(b=>{
    b.addEventListener('click', ()=> {
      const target = (b.dataset.src||'').toLowerCase();
      setActive(target);
      send({action:'setSource', source: target});
    });
    b.addEventListener('pointerenter', pingInteraction, {passive:true});
  });
  document.getElementById('refresh').addEventListener('click', ()=> {
    send({action:'refresh'});
    pingInteraction();
  });

  window.setStatus = function(txt){ st.textContent = txt || '\u2014'; }

  window.setVol = function(n, quiet){ setVol(n, quiet); }

  if (glass) {
    ['pointermove','pointerdown','wheel','keydown','touchstart'].forEach(evt => {
      glass.addEventListener(evt, pingInteraction, {passive:true});
    });
  }

  updateSliderVisuals(s.value);
  send({action:'interaction'});
</script>

]], initVol, sliderKnobMarkup, initVol)

local uc = hs.webview.usercontent.new("kef")
uc:setCallback(function(msg)
  if type(msg.body) ~= "table" then return end
  local b = msg.body
  if b.action == "setVol" and b.vol then
    local vol = tonumber(b.vol)
    if vol then
      kefSetVol(vol, function(v)
        currentVol = v
        if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d,true)"):format(v)) end
        if _G.kefWV then armAutoClose(15) end
      end)
    end
  elseif b.action == "setSource" and b.source then
    if kefSetSource then kefSetSource(b.source) end
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setInput('%s')"):format(b.source or "")) end
    kefRefresh()
    hs.timer.doAfter(0.4, function() if kefRefresh then kefRefresh() end end)
    if _G.kefWV then armAutoClose(15) end
  elseif b.action == "refresh" then
    if kefRefresh then kefRefresh() end
    if _G.kefWV then armAutoClose(15) end
  elseif b.action == "interaction" then
    if _G.kefWV then armAutoClose(15) end
  elseif b.action == "close" then
    local delay = tonumber(b.delay)
    local lock = b.lock ~= false
    if delay and delay > 0 then
      armAutoClose(delay, { force = lock })
    else
      dismissPopover()
    end
  end
end)

local function newPopover()
  local wf = scr.mainScreen():fullFrame()
  local w,h = 360, 260
  local x = wf.x + wf.w - w - 12
  local y = wf.y + 40
  local wv = hs.webview.new({x=x,y=y,w=w,h=h}, {developerExtrasEnabled=false}, uc)
  wv:windowStyle({"utility"})
    :allowNewWindows(false)
    :allowGestures(true)
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.modalPanel)
    :html(html)
    :transparent(true)
  if kefPos and kefPos.x and kefPos.y then
    wv:topLeft(kefPos)
  end
  return wv
end

_G.kefWV = nil
local function togglePopover()
  if _G.kefWV and _G.kefWV:hswindow() then
    dismissPopover()
    return
  end
  autoCloseLocked = false
  _G.kefWV = newPopover()
  _G.kefWV:show()
  armAutoClose(15)
  if kefRefresh then kefRefresh() end
  _G.kefWV:evaluateJavaScript(("setVol(%d,true)"):format(currentVol or 0))
  kefGetVol(function(v)
    if v then
      currentVol = v
      if _G.kefWV then _G.kefWV:evaluateJavaScript("setStatus('Online')") end
      if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d,true)"):format(v)) end
      kefGetInput(function(name)
        if _G.kefWV then _G.kefWV:evaluateJavaScript(("setInput('%s')"):format(name or "")) end
      end)
      kefGetNowPlaying(function(txt)
        if _G.kefWV then _G.kefWV:evaluateJavaScript(("setNow('%s')"):format(((txt or ""):gsub("[\\']", "\\%0")))) end
      end)
    else
      if _G.kefWV then _G.kefWV:evaluateJavaScript("setStatus('Offline')") end
    end
  end)

  dragTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp
  }, function(e)
    local t = e:getType()
    local pt = hs.mouse.absolutePosition()
    if not _G.kefWV then return false end

    local f = _G.kefWV:frame()
    local inside = (pt.x >= f.x and pt.x <= f.x+f.w and pt.y >= f.y and pt.y <= f.y+f.h)
    if not inside then
      return false
    end

    local flags = hs.eventtap.checkKeyboardModifiers() or {}
    local headerHeight = 32
    local closeZoneWidth = 64
    local inHeaderBand = (pt.y >= f.y and pt.y <= f.y + headerHeight)
    local inCloseZone = inHeaderBand and (pt.x >= (f.x + f.w - closeZoneWidth))
    local allowDrag = (flags.cmd or inHeaderBand) and not inCloseZone

    if t == hs.eventtap.event.types.leftMouseDown then
      if not allowDrag then
        return false
      end
      _G.__kefDragOffset = { dx = pt.x - f.x, dy = pt.y - f.y }
      return true
    elseif t == hs.eventtap.event.types.leftMouseDragged then
      if not _G.__kefDragOffset then return false end
      local nx = pt.x - _G.__kefDragOffset.dx
      local ny = pt.y - _G.__kefDragOffset.dy
      _G.kefWV:topLeft({x=nx,y=ny})
      hs.settings.set('kef.pos', {x=nx, y=ny})
      return true
    elseif t == hs.eventtap.event.types.leftMouseUp then
      if _G.__kefDragOffset then _G.__kefDragOffset = nil return true end
      return false
    end
    return false
  end):start()

  dismissTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
    local pt = hs.mouse.absolutePosition()
    if not _G.kefWV then return false end
    local f = _G.kefWV:frame()
    local inside = (pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h)
    if not inside then
      dismissPopover()
    end
    return false
  end):start()
end

menu:setClickCallback(togglePopover)

-- ---------- Background poll to keep in sync ----------
local function refresh()
  kefGetVol(function(v)
    if v then currentVol = v end
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d,true)"):format(currentVol or 0)) end
  end)
end

timer.doEvery(POLL_SECONDS, refresh)

-- ---------- F18/F19 hotkeys (DOIO knob) ----------
hs.hotkey.bind({}, "F18", function()
  kefSetVol((currentVol or 0) - STEP, function(v)
    currentVol = v
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d)"):format(v)) end
    if _G.kefWV then armAutoClose(15) end
  end)
end)
hs.hotkey.bind({}, "F19", function()
  kefSetVol((currentVol or 0) + STEP, function(v)
    currentVol = v
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d)"):format(v)) end
    if _G.kefWV then armAutoClose(15) end
  end)
end)

hs.alert.show("KEF W loaded")
