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

local function lerpAngle(a, b, k)
    local d = (b - a + 540.0) % 360.0 - 180.0
    return a + d * k
end

--- Interpolated pose of track T at time t (ms).
function P.Sample(T, t)
    local n = T.n
    local i = bsearch(T.t, n, t)
    local j = math.min(i + 1, n)
    local span = T.t[j] - T.t[i]
    local k = span > 0 and math.max(0.0, math.min(1.0, (t - T.t[i]) / span)) or 0.0
    return {
        x = T.x[i] + (T.x[j] - T.x[i]) * k,
        y = T.y[i] + (T.y[j] - T.y[i]) * k,
        z = T.z[i] + (T.z[j] - T.z[i]) * k,
        p = lerpAngle(T.p[i], T.p[j], k),
        r = lerpAngle(T.r[i], T.r[j], k),
        h = lerpAngle(T.h[i], T.h[j], k),
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

--- row: listing columns + racers (JSON); tracks: Codec.Decode output.
function P.Load(row, tracks)
    P.row = row
    P.metas = json.decode(row.racers or "[]") or {}
    P.tracks = tracks
    P.duration = 0
    for _, T in ipairs(tracks) do
        if T.n > 0 and T.t[T.n] > P.duration then P.duration = T.t[T.n] end
    end
    P.t, P.speedIdx, P.paused = 0, 3, false
    for i, s in ipairs(Config.Speeds) do if s == 1.0 then P.speedIdx = i end end
    P.cars = {}

    for i, T in ipairs(tracks) do
        local meta = P.metas[i] or {}
        if T.n > 0 and loadModel(meta.model) then
            local veh = CreateVehicle(meta.model, T.x[1], T.y[1], T.z[1], T.h[1], false, false)
            SetEntityCollision(veh, false, false)
            FreezeEntityPosition(veh, true)
            SetEntityInvincible(veh, true)
            SetVehicleColours(veh, meta.colours and meta.colours[1] or 0, meta.colours and meta.colours[2] or 0)
            if meta.plate then SetVehicleNumberPlateText(veh, meta.plate) end
            SetVehicleWindowTint(veh, 1)          -- dark glass: the cars have no drivers
            SetVehicleEngineOn(veh, true, true, false)
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

--- Advance the clock and pose every car. Returns the target's sample.
function P.Step(dtMs)
    if not P.paused then
        P.t = P.t + dtMs * Config.Speeds[P.speedIdx]
        if P.t >= P.duration then P.t = P.duration; P.paused = true end
    end
    local targetSample
    for i, veh in pairs(P.cars) do
        local s = P.Sample(P.tracks[i], P.t)
        if s.gone then
            SetEntityVisible(veh, false, false)
        else
            SetEntityVisible(veh, true, false)
            SetEntityCoordsNoOffset(veh, s.x, s.y, s.z, false, false, false)
            SetEntityRotation(veh, s.p, s.r, s.h, 2, false)
        end
        if i == P.target then targetSample = s end
    end
    return targetSample
end

function P.Seek(ms) P.t = math.max(0, math.min(P.duration, ms)) end

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
