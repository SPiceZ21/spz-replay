-- client/cameras.lua — the replay camera rig.
--
-- One scripted camera. Each mode computes where the camera WANTS to be, what
-- it wants to look at and its zoom; all three are then eased toward that with
-- framerate-independent exponential smoothing, so nothing ever snaps:
-- switching mode, switching driver, seeking and scrubbing all glide.
--   CHASE   behind and above the car, swings wide into corners
--   TV      trackside cameras along the car's line (cuts between spots like
--           broadcast TV, but the pan and zoom are smooth)
--   HELI    high and behind
--   BONNET  on the nose
--   WHEEL   low on the side, by the front wheel
--   FREE    fly anywhere: WASD + mouse, R/F up/down, Shift fast (smoothed)

Cams = {}
Cams.Modes = { "CHASE", "TV", "HELI", "BONNET", "WHEEL", "FREE" }

local cam = nil
local mode = 1
local cur = nil      -- { pos, look, fov } — what the camera shows right now
local tv = { spots = {}, idx = 1, forTarget = nil }
local free = { pos = vector3(0, 0, 0), rot = vector3(0, 0, 0), vel = vector3(0, 0, 0), look = vector2(0, 0) }

-- Per-mode responsiveness (higher = tighter). Position, look point, zoom.
local GAIN = {
    CHASE  = { 5.0, 9.0, 4.0 },
    TV     = { 99.0, 6.0, 3.0 },   -- position cuts between spots; pan/zoom ease
    HELI   = { 2.2, 3.5, 3.0 },
    BONNET = { 40.0, 30.0, 6.0 },  -- rigid to the car (the car itself is smooth)
    WHEEL  = { 30.0, 22.0, 6.0 },
}

local function ease(a, b, gain, dt) return a + (b - a) * (1 - math.exp(-gain * dt)) end

function Cams.Name() return Cams.Modes[mode] end

function Cams.Start(at)
    cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, at.x, at.y, at.z + 5.0)
    SetCamFov(cam, 60.0)
    RenderScriptCams(true, false, 0, true, true)
    cur = nil
end

function Cams.Stop()
    if cam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
        cam = nil
    end
    ClearFocus()
    cur = nil
end

function Cams.Cycle(dir)
    mode = ((mode - 1 + (dir or 1)) % #Cams.Modes) + 1
    if Cams.Modes[mode] == "FREE" and cam then
        free.pos = GetCamCoord(cam)
        free.rot = GetCamRot(cam, 2)
        free.vel = vector3(0, 0, 0)
    end
    -- `cur` is kept: the camera glides from the old shot to the new one.
end

--- New driver: glide over, unless they're far away (then cut).
function Cams.OnTargetChanged(newPos)
    tv.forTarget = nil
    if cur and newPos and #(cur.look - newPos) > 150.0 then cur = nil end
end

--- The car teleported (rewind / reset to checkpoint): cut, don't chase.
function Cams.Snap() cur = nil end

-- ── TV spots ─────────────────────────────────────────────────────────────────

local function buildTv(T, key)
    local spots, dist, side = {}, Config.TvSpacing, 1
    for i = 2, T.n do
        local dx, dy = T.x[i] - T.x[i - 1], T.y[i] - T.y[i - 1]
        dist = dist + math.sqrt(dx * dx + dy * dy)
        if dist >= Config.TvSpacing then
            dist = 0
            local h = math.rad(T.h[i])
            local rx, ry = math.cos(h), math.sin(h)   -- right of heading
            spots[#spots + 1] = vector3(T.x[i] + rx * Config.TvSide * side,
                                        T.y[i] + ry * Config.TvSide * side, T.z[i] + Config.TvHeight)
            side = -side
        end
    end
    tv.spots, tv.idx, tv.forTarget = spots, 1, key
end

local function pickTv(p)
    local s = tv.spots
    if #s == 0 then return nil end
    local best, bestD = tv.idx, #(s[tv.idx] - p)
    for i = math.max(1, tv.idx - 2), math.min(#s, tv.idx + 3) do
        local d = #(s[i] - p)
        if d < bestD - 6.0 then best, bestD = i, d end   -- hysteresis: no flicker between two spots
    end
    if bestD > 220.0 then
        for i = 1, #s do
            local d = #(s[i] - p)
            if d < bestD then best, bestD = i, d end
        end
    end
    local cut = best ~= tv.idx
    tv.idx = best
    return s[best], bestD, cut
end

-- ── Free cam (velocity + look smoothing) ─────────────────────────────────────

local function updateFree(dt)
    local fast = IsDisabledControlPressed(0, 21) and 4.0 or 1.0
    local mx, my = GetDisabledControlNormal(0, 1), GetDisabledControlNormal(0, 2)
    free.look = vector2(ease(free.look.x, mx, 18.0, dt), ease(free.look.y, my, 18.0, dt))
    free.rot = vector3(math.max(-89.0, math.min(89.0, free.rot.x - free.look.y * 8.0)), 0.0, free.rot.z - free.look.x * 8.0)

    local h, p = math.rad(free.rot.z), math.rad(free.rot.x)
    local fwd = vector3(-math.sin(h) * math.cos(p), math.cos(h) * math.cos(p), math.sin(p))
    local right = vector3(math.cos(h), math.sin(h), 0.0)
    local want = vector3(0, 0, 0)
    if IsDisabledControlPressed(0, 32) then want = want + fwd end
    if IsDisabledControlPressed(0, 33) then want = want - fwd end
    if IsDisabledControlPressed(0, 35) then want = want + right end
    if IsDisabledControlPressed(0, 34) then want = want - right end
    if IsDisabledControlPressed(0, 45) then want = want + vector3(0, 0, 1) end   -- R
    if IsDisabledControlPressed(0, 23) then want = want - vector3(0, 0, 1) end   -- F
    want = want * (14.0 * fast)
    free.vel = vector3(ease(free.vel.x, want.x, 6.0, dt), ease(free.vel.y, want.y, 6.0, dt), ease(free.vel.z, want.z, 6.0, dt))
    free.pos = free.pos + free.vel * dt

    SetCamCoord(cam, free.pos.x, free.pos.y, free.pos.z)
    StopCamPointing(cam)
    SetCamRot(cam, free.rot.x, 0.0, free.rot.z, 2)
    SetCamFov(cam, 60.0)
    SetFocusPosAndVel(free.pos.x, free.pos.y, free.pos.z, 0.0, 0.0, 0.0)
    cur = { pos = free.pos, look = free.pos + fwd * 10.0, fov = 60.0 }
end

-- ── Update ───────────────────────────────────────────────────────────────────

--- veh: the watched car (local entity). T/key: its decoded track, for TV.
function Cams.Update(veh, T, key, dt)
    if not cam then return end
    local m = Cams.Modes[mode]
    if m == "FREE" then return updateFree(dt) end
    if not veh or not DoesEntityExist(veh) then return end

    local p = GetEntityCoords(veh)
    -- Flat forward from heading: pitch/roll bumps never shake the chase/heli shot.
    local h = math.rad(GetEntityHeading(veh))
    local fwd = vector3(-math.sin(h), math.cos(h), 0.0)
    local pos, look, fov
    local cut = false

    if m == "CHASE" then
        pos  = p - fwd * 7.0 + vector3(0, 0, 2.3)
        look = p + fwd * 4.0 + vector3(0, 0, 0.8)
        fov  = 62.0
    elseif m == "TV" then
        if tv.forTarget ~= key then buildTv(T, key) end
        local spot, d, isCut = pickTv(p)
        if not spot then Cams.Cycle(1); return end
        pos, look, cut = spot, p + vector3(0, 0, 0.5), isCut
        fov = math.max(8.0, math.min(60.0, math.deg(2 * math.atan(4.5, d))))   -- ~9 m wide frame
    elseif m == "HELI" then
        pos  = p - fwd * 22.0 + vector3(0, 0, 26.0)
        look = p + fwd * 10.0
        fov  = 48.0
    elseif m == "BONNET" then
        pos  = GetOffsetFromEntityInWorldCoords(veh, 0.0, 0.9, 0.85)
        look = GetOffsetFromEntityInWorldCoords(veh, 0.0, 20.0, 0.6)
        fov  = 72.0
    elseif m == "WHEEL" then
        pos  = GetOffsetFromEntityInWorldCoords(veh, -1.45, 1.1, 0.25)
        look = GetOffsetFromEntityInWorldCoords(veh, -0.6, 12.0, 0.2)
        fov  = 68.0
    end

    local g = GAIN[m]
    if not cur then
        cur = { pos = pos, look = look, fov = fov }
    else
        cur.pos  = cut and pos or vector3(ease(cur.pos.x, pos.x, g[1], dt), ease(cur.pos.y, pos.y, g[1], dt), ease(cur.pos.z, pos.z, g[1], dt))
        cur.look = vector3(ease(cur.look.x, look.x, g[2], dt), ease(cur.look.y, look.y, g[2], dt), ease(cur.look.z, look.z, g[2], dt))
        cur.fov  = cut and fov or ease(cur.fov, fov, g[3], dt)
    end

    SetCamCoord(cam, cur.pos.x, cur.pos.y, cur.pos.z)
    PointCamAtCoord(cam, cur.look.x, cur.look.y, cur.look.z)
    SetCamFov(cam, cur.fov)
    SetFocusPosAndVel(cur.pos.x, cur.pos.y, cur.pos.z, 0.0, 0.0, 0.0)
end
