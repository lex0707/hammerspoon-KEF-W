-- KEF LS50W2 menubar slider (glass), seeded from real volume, SF icon

local SPEAKER_IP   = "192.168.1.109"
local POLL_SECONDS = 5
local STEP         = 2

local http  = require("hs.http")
local json  = require("hs.json")
local image = require("hs.image")
local scr   = require("hs.screen")
local timer = require("hs.timer")

local kefPos = hs.settings.get('kef.pos')
local dismissTap, dragTap

local PATH_SOURCE = "settings:/kef/play/physicalSource"   -- returns kefPhysicalSource
local PATH_NOW    = "player:player/data"                  -- rich state/metadata container (includes state; artist/title when available)

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
      if not srcId and phys then srcId = phys end
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
                 function() if cb then cb(v) end end)
end

-- ---------- Menubar: icon only (circle.square.fill) ----------
local menu = hs.menubar.new()
local sym  = image.imageFromName("circle.square.fill")
if sym then menu:setIcon(sym, true) else menu:setTitle("🔘") end

-- Keep % out of the title since we’re using an icon; % shows in the popover while changing

-- ---------- State ----------
local currentVol = kefGetVolSync() or 0  -- seed synchronously so we never start at 0
local initVol = currentVol or 0
-- (If sync fetch failed, background poll will fix it within a few seconds.)

local html = string.format([[ 
<!doctype html><meta charset="utf-8">
<style>
  :root { color-scheme: light dark; }
  html, body { height:100%%; }
  body { overflow:hidden; }
  body {
    margin: 0; background: transparent;
    font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display:flex; align-items:center; justify-content:center;
    color: #fff;
  }
  .glass {
    display:flex; flex-direction:column; gap:10px;
    padding:20px; width: 320px;
    border-radius:22px;
    background: rgba(255,0,0,0.78);
    box-shadow: 0 12px 36px rgba(0,0,0,0.35), inset 0 1px 0 rgba(255,255,255,0.25);
    backdrop-filter: saturate(200%%) blur(40px);
    -webkit-backdrop-filter: saturate(200%%) blur(40px);
    border:1px solid rgba(255,255,255,0.18);
  }
  @media (prefers-color-scheme: dark) {
    .glass {
      background: rgba(255,0,0,0.72);
      border-color: rgba(255,255,255,0.14);
      box-shadow: 0 14px 44px rgba(0,0,0,0.6), inset 0 2px 0 rgba(255,255,255,0.08);
    }
  }
  h1 {
    margin: 0 0 8px 0; color:#fff;
    font-size: 13px; font-weight: 600; letter-spacing: 0.2px;
    opacity: .92; text-align:left;
  }
  .row { display:flex; align-items:center; gap:12px; }
  input[type=range]{
    -webkit-appearance: none;
    width: 236px; height: 6px; border-radius: 999px;
    background: #ffffff;
    outline: none;
  }
  input[type=range]::-webkit-slider-runnable-track{
    height: 6px; border-radius: 999px; background: #ffffff;
  }
  input[type=range]::-webkit-slider-thumb{
    -webkit-appearance: none;
    width: 18px; height: 18px; border-radius: 50%%;
    background: #ffffff; border: 1px solid rgba(255,255,255,0.45);
    box-shadow: 0 1px 3px rgba(0,0,0,.35);
    margin-top: -6px; /* centers 18px thumb over 6px track */
    cursor: pointer;
  }
  #val { width: 46px; text-align: right; font-variant-numeric: tabular-nums; opacity: 0; transition: opacity .2s ease; }
  .mutebtn {
    padding: 4px 10px; border-radius: 10px; border: 1px solid rgba(255,255,255,.35);
    background: rgba(255,255,255,.15); color:#fff; cursor: pointer; user-select: none;
  }
  @media (prefers-color-scheme: dark) {
    .mutebtn { border-color: rgba(255,255,255,.18); background: rgba(255,255,255,.10); }
  }
  .meta { font-size:12px; opacity:.85; display:flex; gap:12px; }
  .meta div { white-space:nowrap; }
  .inputs { display:flex; gap:8px; flex-wrap:wrap; }
  .inputs button { font-size:12px; padding:4px 8px; border-radius:8px; border:1px solid rgba(255,255,255,.25); background: rgba(255,255,255,.12); color:#fff; cursor:pointer; }
  .inputs button.active { background:#fff; color:#b00000; border-color:#fff; }
  .now { font-size:12px; opacity:.92; margin-top:4px; }
  ::-webkit-scrollbar { width:0; height:0; }
</style>
<div class="glass">
  <h1>KEF W</h1>
  <div class="row">
    <input id="slider" type="range" min="0" max="100" value="%d">
    <div id="val">%d%%</div>
    <button id="mute" class="mutebtn">Mute</button>
  </div>
  <div class="meta"><div id="status">Status: —</div><div id="input">Input: —</div></div>
  <div class="now" id="now">Now Playing: —</div>
  <div class="inputs">
    <button data-src="wifi">Wi‑Fi</button>
    <button data-src="bt">BT</button>
    <button data-src="optical">Optical</button>
    <button data-src="tv">TV</button>
    <button data-src="hdmi">HDMI</button>
    <button id="refresh">Refresh</button>
  </div>
</div>
<script>
  const s = document.getElementById('slider');
  const v = document.getElementById('val');
  const m = document.getElementById('mute');
  const st = document.getElementById('status');
  const inp = document.getElementById('input');
  const now = document.getElementById('now');
  let hideTimer = null, dragging=false;

  function showTemp(n){
    v.textContent = (Math.round(n)||0) + '%%';
    v.style.opacity = 1;
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(()=>{ v.style.opacity = 0; }, 1200);
  }
  function send(msg){
    try{ window.webkit.messageHandlers.kef.postMessage(msg); }catch(e){}
  }
  // external: set volume from Lua (quiet update during refresh)
  function setVol(n, quiet){
    if (dragging && !quiet) return; // don't fight user
    s.value = n; if (!quiet) showTemp(n);
  }
  function beginDrag(){ dragging=true; }
  function endDrag(){ dragging=false; }
  s.addEventListener('pointerdown', beginDrag, {passive:true});
  window.addEventListener('pointerup', endDrag, {passive:true});
  s.addEventListener('mousedown', beginDrag, {passive:true});
  window.addEventListener('mouseup', endDrag, {passive:true});
  s.addEventListener('touchstart', beginDrag, {passive:true});
  window.addEventListener('touchend', endDrag, {passive:true});
  s.addEventListener('input',  ()=> showTemp(s.value));
  s.addEventListener('change', ()=> send({action:'setVol', vol: parseInt(s.value)}));
  m.addEventListener('click',  ()=> { send({action:'setVol', vol:0}); showTemp(0); });

  // inputs
  function setActive(name){
    const norm = (name||'').toLowerCase();
    if (!norm) { document.querySelectorAll('.inputs button').forEach(b=>b.classList.remove('active')); return; }
    const alias = (norm === 'hdmi') ? ['hdmi','tv'] : (norm === 'tv') ? ['hdmi','tv'] : [norm];
    document.querySelectorAll('.inputs button[data-src]').forEach(b=>{
      const id = (b.dataset.src||'').toLowerCase();
      if (alias.includes(id)) b.classList.add('active'); else b.classList.remove('active');
    });
  }
  window.setInput = function(name){
    setActive(name);
    const label = (name||'—');
    inp.textContent = 'Input: ' + (label.toLowerCase()==='tv' ? 'TV' : label);
  }
  window.setNow = function(txt){ now.textContent = 'Now Playing: ' + (txt||'—'); }
  document.querySelectorAll('.inputs button[data-src]').forEach(b=>{
    b.addEventListener('click', ()=> { setActive(b.dataset.src); send({action:'setSource', source:b.dataset.src}); });
  });
  document.getElementById('refresh').addEventListener('click', ()=> send({action:'refresh'}));

  // external status updates
  window.setStatus = function(txt){ st.textContent = 'Status: ' + (txt||'—'); }

  window.setVol = setVol;
</script>
]], initVol, initVol)

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
      end)
    end
  elseif b.action == "setSource" and b.source then
    if kefSetSource then kefSetSource(b.source) end
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setInput('%s')"):format(b.source or "")) end
    kefRefresh()
    hs.timer.doAfter(0.4, function() if kefRefresh then kefRefresh() end end)
  elseif b.action == "refresh" then
    if kefRefresh then kefRefresh() end
  elseif b.vol then -- legacy path
    local vol = tonumber(b.vol)
    if vol then
      kefSetVol(vol, function(v)
        currentVol = v
        if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d,true)"):format(v)) end
      end)
    end
  end
end)

local function newPopover()
  local wf = scr.mainScreen():fullFrame()
  local w,h = 340, 200
  local x = wf.x + wf.w - w - 12
  local y = wf.y + 28
  local wv = hs.webview.new({x=x,y=y,w=w,h=h}, {developerExtrasEnabled=false}, uc)
  wv:windowStyle({"utility"})
    :allowNewWindows(false)
    :allowGestures(true)
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.modalPanel)
    :html(html)
    :transparent(false)          -- << no black window; only the card
  if kefPos and kefPos.x and kefPos.y then
    wv:topLeft(kefPos)
  end
  return wv
end

_G.kefWV = nil
local function togglePopover()
  if _G.kefWV and _G.kefWV:hswindow() then
    _G.kefWV:delete(); _G.kefWV=nil
    if dragTap then dragTap:stop(); dragTap = nil end
    if dismissTap then dismissTap:stop(); dismissTap = nil end
    return
  end
  _G.kefWV = newPopover()
  _G.kefWV:show()
  if kefRefresh then kefRefresh() end
  -- kefDetectPaths removed: endpoints must be set manually for your firmware.
  -- Seed the slider with the *current* value immediately, no 0 flash
  _G.kefWV:evaluateJavaScript(("setVol(%d,true)"):format(currentVol or 0))
  -- Also re-verify from speaker once more
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

  local function frameContains(pt)
    if not _G.kefWV then return false end
    local f = _G.kefWV:frame()
    return pt.x >= f.x and pt.x <= f.x+f.w and pt.y >= f.y and pt.y <= f.y+f.h
  end

  dragTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp
  }, function(e)
    local t = e:getType()
    local pt = hs.mouse.absolutePosition()
    if not _G.kefWV then return false end

    -- Helper: is point inside window frame?
    local f = _G.kefWV:frame()
    local inside = (pt.x >= f.x and pt.x <= f.x+f.w and pt.y >= f.y and pt.y <= f.y+f.h)
    if not inside then
      -- If click is outside, we never consume it.
      return false
    end

    -- Only allow drag start if in the top header band or holding ⌘
    local flags = hs.eventtap.checkKeyboardModifiers() or {}
    local inHeaderBand = (pt.y >= f.y and pt.y <= f.y + 24)  -- ~24px from top
    local allowDrag = flags.cmd or inHeaderBand

    if t == hs.eventtap.event.types.leftMouseDown then
      if not allowDrag then
        -- Don't consume: let webview controls receive the click
        return false
      end
      _G.__kefDragOffset = { dx = pt.x - f.x, dy = pt.y - f.y }
      return true  -- we will handle subsequent drag/up events
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

  dismissTap = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function(e)
    local pt = hs.mouse.absolutePosition()
    if _G.kefWV and not frameContains(pt) then
      _G.kefWV:delete(); _G.kefWV = nil
      if dragTap then dragTap:stop(); dragTap = nil end
      if dismissTap then dismissTap:stop(); dismissTap = nil end
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

-- Initial seed already done synchronously; still start the poller
timer.doEvery(POLL_SECONDS, refresh)

-- ---------- F18/F19 hotkeys (DOIO knob) ----------
hs.hotkey.bind({}, "F18", function()
  kefSetVol((currentVol or 0) - STEP, function(v)
    currentVol = v
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d)"):format(v)) end
  end)
end)
hs.hotkey.bind({}, "F19", function()
  kefSetVol((currentVol or 0) + STEP, function(v)
    currentVol = v
    if _G.kefWV then _G.kefWV:evaluateJavaScript(("setVol(%d)"):format(v)) end
  end)
end)

hs.alert.show("KEF W loaded")
