-- server/recorder.lua — records every LIVE race, saves it when results land.
--
-- Two sources per racer:
--   1. The server samples every racer's car at Config.IntervalMs (primary,
--      always works). Only as fresh as the owner's sync; playback cleans and
--      smooths it.
--   2. The racer's own client sends its exact pose in batches
--      (client/recorder.lua). Finer, so it is used when it covers the race.
-- Finish() picks per racer, so a race is never lost to either side failing.
-- Client frames are only accepted while a recording is open, from players
-- who are (or just were) in the race, in order, with sane values, capped.

Replay = Replay or {}

local Rec = nil   -- { raceId, info, startedAt, live, saved, racers = { [src] = {...} }, order = { src... } }

local MAX_BATCH = 40

local function newRacerFor(rec, src, cm)
    local st = Player(src).state
    local id = #rec.order + 1
    rec.order[id] = src
    rec.racers[src] = {
        id = id,
        frames = {},
        lastT = -1,
        meta = {
            id      = id,
            name    = st.username or GetPlayerName(src) or ("Driver " .. id),
            crew    = st.crewTag,
            nation  = st.nation,
            number  = st.raceNumber,
            model   = tonumber(cm.model) or 0,
            colours = { tonumber(cm.c1) or 0, tonumber(cm.c2) or 0 },
            plate   = type(cm.plate) == "string" and cm.plate:sub(1, 8) or nil,
        },
    }
    return rec.racers[src]
end
local function newRacer(src, cm) return newRacerFor(Rec, src, cm) end

-- One log line per player per race for a rejected batch, so a client that
-- sends but never lands is visible in the console instead of silent.
local function reject(rec, src, why)
    rec.rejected = rec.rejected or {}
    if rec.rejected[src] then return end
    rec.rejected[src] = true
    print(("^3[spz-replay] ignoring frames from %s (%s): %s^7"):format(GetPlayerName(src) or src, src, why))
end

local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

RegisterNetEvent("spz-replay:frames", function(raceId, carMeta, frames)
    local src = source
    local rec = Rec
    if not rec then return end
    if rec.saved then return reject(rec, src, "race already saved") end
    if type(frames) ~= "table" then
        -- Older argument layouts: (raceId, frames) with the meta left out.
        if type(carMeta) == "table" and carMeta[1] then frames, carMeta = carMeta, nil
        else return reject(rec, src, "no frames in the batch") end
    end
    if tostring(raceId) ~= rec.raceId then
        return reject(rec, src, ("race id %s, recording %s"):format(tostring(raceId), rec.raceId))
    end
    local r = rec.racers[src]
    -- New racers only while live and actually racing; a racer we already have
    -- may send their last batch just after finishing.
    if not r then
        if not rec.live then return reject(rec, src, "recording already closed") end
        if not Player(src).state.inRace then return reject(rec, src, "not in the race") end
        if type(carMeta) ~= "table" then return reject(rec, src, "first batch had no car details") end
        r = newRacer(src, carMeta)
        print(("^2[spz-replay] receiving %s's car for race %s^7"):format(r.meta.name, rec.raceId))
    end
    local limit = Config.MaxRaceMin * 60000
    for i = 1, math.min(#frames, MAX_BATCH) do
        local f = frames[i]
        if type(f) == "table" and num(f.t) and num(f.x) and num(f.y) and num(f.z)
            and f.t > r.lastT and f.t <= limit then
            r.frames[#r.frames + 1] = {
                t = f.t, x = f.x, y = f.y, z = f.z,
                p = num(f.p) and f.p or 0, r = num(f.r) and f.r or 0, h = num(f.h) and f.h or 0,
                s = num(f.s) and math.max(0, math.min(f.s, 999)) or 0,
                pos = tonumber(f.pos) or 0, lap = tonumber(f.lap) or 0,
            }
            r.lastT = f.t
        end
    end
end)

-- ── Server recording (primary) ───────────────────────────────────────────────
-- The server samples every racer's car itself at Config.IntervalMs, the way
-- replays were first recorded. This always works. It is only as fresh as the
-- owner's sync, so playback (client/player.lua cleanTrack) drops repeated
-- stale positions and the curve interpolation smooths the rest. When a
-- racer's own client data arrives too (finer, exact), Finish() prefers it.
local function vehicleOf(src)
    local ok, v = pcall(function() return exports["spz-vehicles"]:GetPlayerVehicle(src) end)
    local ent = ok and v and v.entity
    if ent and DoesEntityExist(ent) then return ent end
    return nil
end

local function backupSample(rec)
    local t = GetGameTimer() - rec.startedAt
    for _, sid in ipairs(GetPlayers()) do
        local src = tonumber(sid)
        local st = Player(src).state
        local veh = st.inRace and vehicleOf(src)
        if veh then
            local b = rec.backup[src]
            if not b then
                local c1, c2 = GetVehicleColours(veh)
                b = { frames = {}, meta = { model = GetEntityModel(veh), c1 = c1, c2 = c2,
                                            plate = GetVehicleNumberPlateText(veh) } }
                rec.backup[src] = b
            end
            local c, rot, v = GetEntityCoords(veh), GetEntityRotation(veh), GetEntityVelocity(veh)
            b.frames[#b.frames + 1] = {
                t = t, x = c.x, y = c.y, z = c.z, p = rot.x, r = rot.y, h = rot.z,
                s = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) * 3.6,
                pos = tonumber(st.racePosition) or 0, lap = tonumber(st.raceLap) or 0,
            }
        end
    end
end

local function start()
    local ok, info = pcall(function() return exports["spz-races"]:GetRaceInfo() end)
    info = ok and info or {}
    Rec = { raceId = tostring(info.raceId or os.time()), info = info, startedAt = GetGameTimer(),
            live = true, racers = {}, order = {}, backup = {} }
    local mine = Rec
    CreateThread(function()
        local limit = Config.MaxRaceMin * 60000
        while mine.live and GetGameTimer() - mine.startedAt < limit do
            backupSample(mine)
            Wait(Config.IntervalMs)
        end
    end)
    GlobalState:set("replayRaceId", Rec.raceId, true)   -- clients tag their batches with it
    print(("^2[spz-replay] recording race %s (%s)^7"):format(Rec.raceId, tostring(info.track)))
end

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value == "LIVE" then
        if not Rec or not Rec.live then start() end
    elseif Rec and Rec.live and (value == "ENDED" or value == "IDLE" or value == "CLEANUP") then
        Rec.live = false          -- stop sampling; SPZ:raceEnd saves it
        local mine = Rec
        SetTimeout(20000, function()   -- no results arrived (aborted race): drop it
            if Rec == mine and not mine.saved then Rec = nil end
        end)
    end
end)

AddEventHandler("SPZ:raceEnd", function(results)
    local rec = Rec
    if not rec or rec.saved or type(results) ~= "table" then return end
    rec.live = false
    -- Clients flush every second; give the last batches time to land.
    SetTimeout(2000, function() Replay.Finish(rec, results) end)
end)

function Replay.Finish(rec, results)
    if rec.saved then return end
    rec.saved = true

    -- Fill in anyone whose client sent nothing (or almost nothing) from the
    -- server backup.
    for src, b in pairs(rec.backup or {}) do
        local r = rec.racers[src]
        -- Client data wins only if it covers most of the race; otherwise the
        -- server recording is used.
        local lastC = r and r.frames[#r.frames]
        local lastB = b.frames[#b.frames]
        local covers = lastC and lastB and lastC.t >= lastB.t * 0.9
        if not covers and #b.frames > 0 then
            if not r then r = newRacerFor(rec, src, b.meta) end
            local F = b.frames
            local anySpeed = false
            for i = 1, #F do if F[i].s > 1 then anySpeed = true; break end end
            for i = 1, anySpeed and 0 or #F do   -- no usable velocity: derive from movement
                local a, c = F[math.max(i - 1, 1)], F[math.min(i + 1, #F)]
                local dt = (c.t - a.t) / 1000
                local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
                F[i].s = dt > 0 and math.sqrt(dx * dx + dy * dy + dz * dz) / dt * 3.6 or 0
            end
            r.frames = F
            print(("^2[spz-replay] %s: server recording (%d frames)^7"):format(r.meta.name, #b.frames))
        end
    end
    if #rec.order == 0 then
        print(("^3[spz-replay] race %s not saved: no racer sent any frames^7"):format(rec.raceId))
        if Rec == rec then Rec = nil end
        return
    end

    local duration = 0
    for _, r in pairs(rec.racers) do
        local last = r.frames[#r.frames]
        if last and last.t > duration then duration = last.t end
    end
    if duration < Config.MinRaceSec * 1000 then
        print(("^3[spz-replay] race %s not saved: only %.1fs recorded (min %ds)^7"):format(
            rec.raceId, duration / 1000, Config.MinRaceSec))
        if Rec == rec then Rec = nil end
        return
    end

    -- Finish order / times from the results, matched by source.
    for _, f in ipairs(results.finishers or {}) do
        local r = rec.racers[f.source]
        if r then r.meta.pos = f.position; r.meta.time = f.finish_time; r.meta.best = f.best_lap end
    end
    for _, d in ipairs(results.dnf or {}) do
        local r = rec.racers[d.source]
        if r then r.meta.dnf = true end
    end

    local metas, tracks = {}, {}
    for i, src in ipairs(rec.order) do
        metas[i] = rec.racers[src].meta
        tracks[i] = rec.racers[src].frames
    end
    local winner = results.finishers and results.finishers[1] and results.finishers[1].name

    CreateThread(function()
        Replay.Save({
            raceId   = rec.raceId,
            track    = results.track or rec.info.track or "Unknown",
            trackId  = results.trackId or rec.info.trackId,
            raceType = results.type or rec.info.type or "circuit",
            laps     = tonumber(results.laps) or 1,
            carClass = results.carClass and tostring(results.carClass) or nil,
            duration = duration,
            winner   = winner,
            racers   = metas,
            blob     = Codec.Encode(tracks),
        })
        if Rec == rec then Rec = nil end
    end)
end

function Replay.IsRecording() return Rec ~= nil and Rec.live == true end
