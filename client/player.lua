-- client/player.lua — the playback engine.
--
-- The replay's cars are LOCAL vehicles (not networked, nobody else sees them),
-- frozen with collision off, and posed every frame by interpolating between
-- the two recorded frames around the playback clock. The viewer's own ped is
-- parked invisible at the start of the track for the duration.

Play = { active = false }

local P = Play

local function bsearch(ts, n, t)
    if t <= ts[1] then return 1 end
    if t >= ts[n] then return n end
    local lo, hi = 1, n
    while hi - lo > 1 do
        local mid = (lo + hi) // 2
        if ts[mid] <= t then lo = mid else hi = mid end
    end
    return lo
end

-- Catmull-Rom through four samples: the car follows a smooth curve through
-- the recorded points instead of cornering in straight 10 Hz segments.
local function cr(p0, p1, p2, p3, k)
    local k2, k3 = k * k, k * k * k
    return 0.5 * ((2 * p1) + (-p0 + p2) * k + (2 * p0 - 5 * p1 + 4 * p2 - p3) * k2 + (-p0 + 3 * p1 - 3 * p2 + p3) * k3)
end

-- Angles unwrapped around p1 first, so 179° → -179° is a 2° turn, not 358°.
local function unwrap(a, ref) return ref + ((a - ref + 540.0) % 360.0 - 180.0) end
local function crAngle(a0, a1, a2, a3, k)
    a0, a2 = unwrap(a0, a1), unwrap(a2, a1)
    a3 = unwrap(a3, a2)
    return cr(a0, a1, a2, a3, k)
end

--- Interpolated pose of track T at time t (ms).
function P.Sample(T, t)
    local n = T.n
    local i = bsearch(T.t, n, t)
    local j = math.min(i + 1, n)
    local h0, h3 = math.max(i - 1, 1), math.min(i + 2, n)
    local cut = T.cut
    -- A teleport (rewind / reset to checkpoint) is a hard cut: hold the old
    -- pose until the new one, never slide through the world between them,
    -- and never let a curve reach across it.
    if cut[i] then j = i; h3 = i end
    if cut[h0] then h0 = i end
    if cut[j] then h3 = j end
    local span = T.t[j] - T.t[i]
    local k = span > 0 and math.max(0.0, math.min(1.0, (t - T.t[i]) / span)) or 0.0
    return {
        seg = i,
        x = cr(T.x[h0], T.x[i], T.x[j], T.x[h3], k),
        y = cr(T.y[h0], T.y[i], T.y[j], T.y[h3], k),
        z = cr(T.z[h0], T.z[i], T.z[j], T.z[h3], k),
        p = crAngle(T.p[h0], T.p[i], T.p[j], T.p[h3], k),
        r = crAngle(T.r[h0], T.r[i], T.r[j], T.r[h3], k),
        h = crAngle(T.h[h0], T.h[i], T.h[j], T.h[h3], k),
        s = T.s[i] + (T.s[j] - T.s[i]) * k,
        pos = T.pos[i], lap = T.lap[i],
        gone = t > T.t[n] + Config.HideAfterFinishMs,
    }
end

local function loadModel(model)
    if not IsModelInCdimage(model) then return false end
    RequestModel(model)
    local deadline = GetGameTimer() + 8000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(model)
end

--- Replays recorded before client-side sampling hold the server's view of the
--- car, which only changes when the owner syncs: the same position repeated
--- for several frames, then a jump. Playing that back is stop-go. Keep only
--- the first frame of each repeated run (that is when the position was true)
--- so the curve interpolates across the gap, and rebuild the speed from the
--- positions because those recordings' speeds are stale too.
local function cleanTrack(T)
    if T.n < 3 then return T end
    local keep, dropped = { 1 }, 0
    for i = 2, T.n do
        local j = keep[#keep]
        local dx, dy, dz = T.x[i] - T.x[j], T.y[i] - T.y[j], T.z[i] - T.z[j]
        if dx * dx + dy * dy + dz * dz > 0.0004 or i == T.n then   -- moved > 2 cm
            keep[#keep + 1] = i
        else
            dropped = dropped + 1
        end
    end
    if dropped < T.n * 0.1 then return T end   -- clean recording: leave it alone

    local C = { t = {}, x = {}, y = {}, z = {}, p = {}, r = {}, h = {}, s = {}, pos = {}, lap = {} }
    for n, i in ipairs(keep) do
        C.t[n], C.x[n], C.y[n], C.z[n] = T.t[i], T.x[i], T.y[i], T.z[i]
        C.p[n], C.r[n], C.h[n] = T.p[i], T.r[i], T.h[i]
        C.pos[n], C.lap[n] = T.pos[i], T.lap[i]
    end
    C.n = #keep
    for n = 1, C.n do
        local a, b = math.max(n - 1, 1), math.min(n + 1, C.n)
        local dt = (C.t[b] - C.t[a]) / 1000
        local dx, dy, dz = C.x[b] - C.x[a], C.y[b] - C.y[a], C.z[b] - C.z[a]
        local v = dt > 0 and math.sqrt(dx * dx + dy * dy + dz * dz) / dt * 3.6 or 0
        C.s[n] = v <= 400 and v or 999   -- across a teleport: fixed up in markCuts
    end
    return C
end

--- Mark teleports: cut[i] = true when the car jumps between frame i and
--- i+1 further than it could drive (rewind, F4 reset to checkpoint, respawn).
--- Speeds next to a cut are taken from the side that isn't a jump.
local MAX_MPS = 110.0   -- ~400 km/h

local function markCuts(T)
    T.cut = {}
    for i = 1, T.n - 1 do
        local dt = math.max(0.05, (T.t[i + 1] - T.t[i]) / 1000)
        local dx, dy, dz = T.x[i + 1] - T.x[i], T.y[i + 1] - T.y[i], T.z[i + 1] - T.z[i]
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d > 8.0 and d / dt > MAX_MPS then T.cut[i] = true end
    end
    for i = 1, T.n do
        if T.s[i] > 400 then T.s[i] = (T.cut[i - 1] and T.s[i + 1]) or (T.s[i - 1] or 0) end
    end
    return T
end

--- row: listing columns + racers (JSON); tracks: Codec.Decode output.
function P.Load(row, tracks)
    P.row = row
    P.metas = json.decode(row.racers or "[]") or {}
    for i, T in ipairs(tracks) do tracks[i] = markCuts(cleanTrack(T)) end
    P.tracks = tracks
    P.duration = 0
    for _, T in ipairs(tracks) do
        if T.n > 0 and T.t[T.n] > P.duration then P.duration = T.t[T.n] end
    end
    P.t, P.speedIdx, P.paused, P.rate, P.seekTo = 0, 3, false, 0.0, nil
    for i, s in ipairs(Config.Speeds) do if s == 1.0 then P.speedIdx = i end end
    P.cars = {}

    for i, T in ipairs(tracks) do
        local meta = P.metas[i] or {}
        if T.n > 0 and loadModel(meta.model) then
            local veh = CreateVehicle(meta.model, T.x[1], T.y[1], T.z[1], T.h[1], false, false)
            SetEntityCollision(veh, false, false)
            -- Not frozen: a frozen car's wheels and engine never move. Gravity
            -- off and collision off, and it is placed every frame anyway, so it
            -- still goes exactly where the recording says.
            SetEntityHasGravity(veh, false)
            SetEntityInvincible(veh, true)
            SetVehicleColours(veh, meta.colours and meta.colours[1] or 0, meta.colours and meta.colours[2] or 0)
            if meta.plate then SetVehicleNumberPlateText(veh, meta.plate) end
            SetVehicleWindowTint(veh, 1)          -- dark glass: the cars have no drivers
            SetVehicleEngineOn(veh, true, true, true)
            SetVehicleUndriveable(veh, false)
            if type(SetVehicleKeepEngineOnWhenAbandoned) == "function" then SetVehicleKeepEngineOnWhenAbandoned(veh, true) end
            SetVehicleLights(veh, 2)
            SetVehicleDirtLevel(veh, 0.0)
            SetEntityLodDist(veh, 1000)
            SetModelAsNoLongerNeeded(meta.model)
            P.cars[i] = veh
            meta.label = GetLabelText(GetDisplayNameFromVehicleModel(meta.model))
            if meta.label == "NULL" then meta.label = GetDisplayNameFromVehicleModel(meta.model) end
        end
    end

    -- Start on the eventual winner, else the first racer with a car.
    P.target = nil
    for i, m in ipairs(P.metas) do if m.pos == 1 and P.cars[i] then P.target = i end end
    if not P.target then for i in pairs(P.cars) do P.target = P.target and math.min(P.target, i) or i end end
    P.active = P.target ~= nil
    return P.active
end

function P.Unload()
    for _, veh in pairs(P.cars or {}) do
        if DoesEntityExist(veh) then DeleteEntity(veh) end
    end
    P.cars, P.tracks, P.metas, P.row = {}, nil, nil, nil
    P.active = false
end

-- ── Wheels + engine ──────────────────────────────────────────────────────────
-- The cars have no drivers, so their wheels and engine are driven from the
-- recording: velocity (what the game's physics and audio read), wheel spin
-- from speed / tyre radius, and revs + gear from a simple 6-speed model of
-- the recorded speed. Only cars near the camera get this; distant ones are
-- just posed.
local AUDIO_RANGE = 160.0
local GEARS, TOP = 6, 320.0           -- km/h at the top of 6th
local hasWheelSpin = type(SetVehicleWheelRotationSpeed) == "function"
local hasRpm       = type(SetVehicleCurrentRpm) == "function"
local hasGear      = type(SetVehicleCurrentGear) == "function"
local hasThrottle  = type(SetVehicleThrottleOffset) == "function"

local function gearAndRpm(kmh)
    if kmh < 3 then return 1, 0.2 end
    for g = 1, GEARS do
        local top = TOP * (g / GEARS) ^ 0.85
        if kmh <= top or g == GEARS then
            local bottom = g == 1 and 0 or TOP * ((g - 1) / GEARS) ^ 0.85
            local k = math.max(0, math.min(1, (kmh - bottom) / (top - bottom)))
            return g, 0.35 + 0.63 * k        -- shift at ~98%, drop to ~35%+
        end
    end
end

local function driveCar(veh, s, rate, accel, near)
    local fwd = GetEntityForwardVector(veh)
    local mps = (s.s or 0) / 3.6 * rate
    SetEntityVelocity(veh, fwd.x * mps, fwd.y * mps, fwd.z * mps)
    if not near then return end

    if hasWheelSpin then
        local wheels = GetVehicleNumberOfWheels(veh)
        for w = 0, wheels - 1 do
            local radius = 0.35
            if type(GetVehicleWheelTireColliderSize) == "function" then
                local r = GetVehicleWheelTireColliderSize(veh, w)
                if r and r > 0.1 then radius = r end
            end
            SetVehicleWheelRotationSpeed(veh, w, -mps / radius)
        end
    end

    local gear, rpm = gearAndRpm(s.s or 0)
    if rate < 0.05 then gear, rpm = 1, 0.2 end         -- paused: idle
    if hasGear then SetVehicleCurrentGear(veh, gear) end
    if hasRpm then SetVehicleCurrentRpm(veh, rpm) end
    if hasThrottle then SetVehicleThrottleOffset(veh, accel > 0.5 and 1.0 or (accel < -2 and -0.5 or 0.2)) end
end

--- Advance the clock and pose every car. Returns the target's sample.
---
--- The clock never jumps. Play speed eases toward its target (so pause and
--- speed changes glide), and a seek or scrub sets P.seekTo, which the clock
--- glides to over a few frames. The cars sweep along their own lines to the
--- new time instead of teleporting.
function P.Step(dtMs)
    local dt = dtMs / 1000
    local want = P.paused and 0.0 or Config.Speeds[P.speedIdx]
    P.rate = (P.rate or 0.0) + (want - (P.rate or 0.0)) * (1 - math.exp(-dt * 7.0))

    if P.seekTo then
        local d = P.seekTo - P.t
        P.t = P.t + d * (1 - math.exp(-dt * 14.0))
        if math.abs(d) < 4 then P.t = P.seekTo; P.seekTo = nil end
    else
        P.t = P.t + dtMs * P.rate
    end
    if P.t >= P.duration then P.t = P.duration; P.paused = true; P.seekTo = nil end
    if P.t < 0 then P.t = 0 end

    local targetSample
    P.lastSpeed = P.lastSpeed or {}
    local camPos = GetFinalRenderedCamCoord()
    for i, veh in pairs(P.cars) do
        local s = P.Sample(P.tracks[i], P.t)
        if s.gone then
            if IsEntityVisible(veh) then
                SetEntityVisible(veh, false, false)
                SetEntityVelocity(veh, 0.0, 0.0, 0.0)
                SetVehicleEngineOn(veh, false, true, true)   -- a finished car goes quiet too
            end
        else
            if not IsEntityVisible(veh) then
                SetEntityVisible(veh, true, false)
                SetVehicleEngineOn(veh, true, true, true)
            end
            SetEntityCoordsNoOffset(veh, s.x, s.y, s.z, false, false, false)
            SetEntityRotation(veh, s.p, s.r, s.h, 2, false)
            -- Acceleration (km/h per s) for the throttle: on it, or lifting.
            local prev = P.lastSpeed[i] or s.s
            local accel = dt > 0 and (s.s - prev) / dt or 0
            P.lastSpeed[i] = s.s
            local near = camPos and #(camPos - vector3(s.x, s.y, s.z)) < AUDIO_RANGE
            driveCar(veh, s, P.rate, accel, near)
        end
        if i == P.target then
            targetSample = s
            -- Crossed a teleport since last frame (playing, seeking or
            -- scrubbing, either direction)? The camera cuts with it.
            local last = P.lastSeg
            if last and last ~= s.seg then
                local a, b = math.min(last, s.seg), math.max(last, s.seg)
                for c = a, b - 1 do
                    if P.tracks[i].cut[c] then P.cutNow = true; break end
                end
            end
            P.lastSeg = s.seg
        end
    end
    return targetSample
end

--- Smooth seek: the clock glides there (see Step).
function P.Seek(ms)
    P.seekTo = math.max(0, math.min(P.duration, ms))
end

--- Where the clock is heading (for chained arrow presses / the timeline).
function P.Goal() return P.seekTo or P.t end

--- Next / previous racer that has a car.
function P.Switch(dir)
    local n = #P.metas
    local i = P.target
    for _ = 1, n do
        i = ((i - 1 + dir) % n) + 1
        if P.cars[i] then P.target = i; return true end
    end
    return false
end

--- Running order at the current time, for the board.
function P.Board()
    local list = {}
    for i, T in ipairs(P.tracks) do
        local s = P.Sample(T, P.t)
        local m = P.metas[i] or {}
        list[#list + 1] = {
            id = i, name = m.name, crew = m.crew, nation = m.nation, number = m.number,
            pos = (s.pos and s.pos > 0) and s.pos or 99, lap = s.lap,
            finished = P.t > T.t[T.n], target = i == P.target,
        }
    end
    table.sort(list, function(a, b) return a.pos < b.pos end)
    return list
end
