-- client/cameras.lua — the replay camera rig.
--
-- One scripted camera, repositioned every frame by the active mode:
--   CHASE   behind and above the car, smoothed so it swings into corners
--   TV      trackside cameras along the car's own line, zooming to keep it framed
--   HELI    high and behind, wide shot of the pack
--   BONNET  on the nose, looking down the road
--   WHEEL   low on the side, by the front wheel
--   FREE    fly anywhere: WASD + mouse, R/F up/down, Shift fast

Cams = {}
Cams.Modes = { "CHASE", "TV", "HELI", "BONNET", "WHEEL", "FREE" }

local cam = nil
local mode = 1
local smooth = nil            -- smoothed chase position
local tv = { spots = {}, idx = 1, forTarget = nil }
local free = { pos = vector3(0, 0, 0), rot = vector3(0, 0, 0) }

local function lerp(a, b, k) return a + (b - a) * k end

function Cams.Name() return Cams.Modes[mode] end

function Cams.Start(at)
    cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, at.x, at.y, at.z + 5.0)
    SetCamFov(cam, 60.0)
    RenderScriptCams(true, false, 0, true, true)
    smooth = nil
end

function Cams.Stop()
    if cam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
        cam = nil
    end
    ClearFocus()
end

function Cams.Cycle(dir)
    mode = ((mode - 1 + (dir or 1)) % #Cams.Modes) + 1
    smooth = nil
    if Cams.Modes[mode] == "FREE" and cam then
        free.pos = GetCamCoord(cam)
        free.rot = GetCamRot(cam, 2)
    end
end

--- New target: chase snaps instead of flying across the map.
function Cams.OnTargetChanged() smooth = nil; tv.forTarget = nil end

--- TV spots along a decoded track: one every Config.TvSpacing metres,
--- alternating sides of the car's line.
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
    -- Stay on the current spot until the next one is clearly closer.
    local best, bestD = tv.idx, #(s[tv.idx] - p)
    for i = math.max(1, tv.idx - 2), math.min(#s, tv.idx + 3) do
        local d = #(s[i] - p)
        if d < bestD - 4.0 then best, bestD = i, d end
    end
    if bestD > 220.0 then   -- seeked far away: full search
        for i = 1, #s do
            local d = #(s[i] - p)
            if d < bestD then best, bestD = i, d end
        end
    end
    tv.idx = best
    return s[best], bestD
end

local function updateFree(dt)
    local fast = IsDisabledControlPressed(0, 21) and 4.0 or 1.0
    local mx, my = GetDisabledControlNormal(0, 1), GetDisabledControlNormal(0, 2)
    free.rot = vector3(math.max(-89.0, math.min(89.0, free.rot.x - my * 8.0)), 0.0, free.rot.z - mx * 8.0)
    local h, p = math.rad(free.rot.z), math.rad(free.rot.x)
    local fwd = vector3(-math.sin(h) * math.cos(p), math.cos(h) * math.cos(p), math.sin(p))
    local right = vector3(math.cos(h), math.sin(h), 0.0)
    local v = vector3(0, 0, 0)
    if IsDisabledControlPressed(0, 32) then v = v + fwd end
    if IsDisabledControlPressed(0, 33) then v = v - fwd end
    if IsDisabledControlPressed(0, 35) then v = v + right end
    if IsDisabledControlPressed(0, 34) then v = v - right end
    if IsDisabledControlPressed(0, 45) then v = v + vector3(0, 0, 1) end   -- R
    if IsDisabledControlPressed(0, 23) then v = v - vector3(0, 0, 1) end   -- F
    free.pos = free.pos + v * (12.0 * fast * dt)
    SetCamCoord(cam, free.pos.x, free.pos.y, free.pos.z)
    SetCamRot(cam, free.rot.x, 0.0, free.rot.z, 2)
    SetCamFov(cam, 60.0)
end

--- veh: the watched car (local entity). T/key: its decoded track, for TV.
function Cams.Update(veh, T, key, dt)
    if not cam then return end
    local m = Cams.Modes[mode]
    if m == "FREE" then
        updateFree(dt)
        SetFocusPosAndVel(free.pos.x, free.pos.y, free.pos.z, 0.0, 0.0, 0.0)
        return
    end
    if not veh or not DoesEntityExist(veh) then return end

    local p = GetEntityCoords(veh)
    local fwd = GetEntityForwardVector(veh)
    local at

    if m == "CHASE" then
        local want = p - fwd * 7.0 + vector3(0, 0, 2.3)
        smooth = smooth and lerp(smooth, want, math.min(1.0, dt * 6.0)) or want
        at = smooth
        SetCamCoord(cam, at.x, at.y, at.z)
        PointCamAtCoord(cam, p.x + fwd.x * 4.0, p.y + fwd.y * 4.0, p.z + 0.8)
        SetCamFov(cam, 62.0)

    elseif m == "TV" then
        if tv.forTarget ~= key then buildTv(T, key) end
        local spot, d = pickTv(p)
        if not spot then Cams.Cycle(1); return end
        at = spot
        SetCamCoord(cam, at.x, at.y, at.z)
        PointCamAtCoord(cam, p.x, p.y, p.z + 0.5)
        -- Keep a ~9 m wide frame on the car whatever the distance.
        SetCamFov(cam, math.max(8.0, math.min(60.0, math.deg(2 * math.atan(4.5, d)))))

    elseif m == "HELI" then
        at = p - fwd * 22.0 + vector3(0, 0, 26.0)
        smooth = smooth and lerp(smooth, at, math.min(1.0, dt * 2.5)) or at
        at = smooth
        SetCamCoord(cam, at.x, at.y, at.z)
        PointCamAtCoord(cam, p.x + fwd.x * 10.0, p.y + fwd.y * 10.0, p.z)
        SetCamFov(cam, 48.0)

    elseif m == "BONNET" then
        at = GetOffsetFromEntityInWorldCoords(veh, 0.0, 0.9, 0.85)
        local rot = GetEntityRotation(veh, 2)
        SetCamCoord(cam, at.x, at.y, at.z)
        StopCamPointing(cam)
        SetCamRot(cam, rot.x, rot.y, rot.z, 2)
        SetCamFov(cam, 72.0)

    elseif m == "WHEEL" then
        at = GetOffsetFromEntityInWorldCoords(veh, -1.45, 1.1, 0.25)
        local look = GetOffsetFromEntityInWorldCoords(veh, -0.6, 12.0, 0.2)
        SetCamCoord(cam, at.x, at.y, at.z)
        PointCamAtCoord(cam, look.x, look.y, look.z)
        SetCamFov(cam, 68.0)
    end

    SetFocusPosAndVel(at.x, at.y, at.z, 0.0, 0.0, 0.0)
end
