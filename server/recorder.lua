-- server/recorder.lua — records every LIVE race, saves it when results land.
--
-- Sampling is server-side (OneSync entity state), so nothing is trusted from
-- clients and nobody's framerate matters. While GlobalState.raceState is LIVE,
-- every Config.IntervalMs each racer's car (the spz-vehicles active vehicle of
-- a player with state.inRace) is sampled into an in-memory track. A racer who
-- finishes stops being sampled; their car holds its last frame. When
-- spz-races fires SPZ:raceEnd the tracks are merged with the results, encoded
-- (shared/codec.lua) and written compressed to `race_replays`.

Replay = Replay or {}

local Rec = nil   -- { raceId, info, startedAt, live, saved, racers = { [src] = {...} }, order = { src... } }

local function vehicleOf(src)
    local ok, v = pcall(function() return exports["spz-vehicles"]:GetPlayerVehicle(src) end)
    local ent = ok and v and v.entity
    if ent and DoesEntityExist(ent) then return ent end
    return nil
end

local function newRacer(src, veh)
    local st = Player(src).state
    local c1, c2 = GetVehicleColours(veh)
    local id = #Rec.order + 1
    Rec.order[id] = src
    Rec.racers[src] = {
        id = id,
        frames = {},
        meta = {
            id      = id,
            name    = st.username or GetPlayerName(src) or ("Driver " .. id),
            crew    = st.crewTag,
            nation  = st.nation,
            number  = st.raceNumber,
            model   = GetEntityModel(veh),
            colours = { c1 or 0, c2 or 0 },
            plate   = GetVehicleNumberPlateText(veh),
        },
    }
    return Rec.racers[src]
end

local function sample()
    local t = GetGameTimer() - Rec.startedAt
    for _, sid in ipairs(GetPlayers()) do
        local src = tonumber(sid)
        local st = Player(src).state
        if st.inRace then
            local veh = vehicleOf(src)
            if veh then
                local r = Rec.racers[src] or newRacer(src, veh)
                local c, rot, v = GetEntityCoords(veh), GetEntityRotation(veh), GetEntityVelocity(veh)
                r.frames[#r.frames + 1] = {
                    t = t, x = c.x, y = c.y, z = c.z,
                    p = rot.x, r = rot.y, h = rot.z,
                    s = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) * 3.6,
                    pos = tonumber(st.racePosition) or 0, lap = tonumber(st.raceLap) or 0,
                }
            end
        end
    end
end

local function start()
    local ok, info = pcall(function() return exports["spz-races"]:GetRaceInfo() end)
    info = ok and info or {}
    Rec = { raceId = tostring(info.raceId or os.time()), info = info, startedAt = GetGameTimer(),
            live = true, racers = {}, order = {} }
    local mine = Rec
    print(("^2[spz-replay] recording race %s (%s)^7"):format(Rec.raceId, tostring(info.track)))
    CreateThread(function()
        local limit = Config.MaxRaceMin * 60000
        while Rec == mine and mine.live do
            sample()
            if GetGameTimer() - mine.startedAt > limit then
                print("^3[spz-replay] race ran past MaxRaceMin, recording stopped^7")
                mine.live = false
                break
            end
            Wait(Config.IntervalMs)
        end
    end)
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
    rec.saved = true
    if #rec.order == 0 then Rec = nil; return end

    local duration = 0
    for _, r in pairs(rec.racers) do
        local last = r.frames[#r.frames]
        if last and last.t > duration then duration = last.t end
    end
    if duration < Config.MinRaceSec * 1000 then Rec = nil; return end

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
end)

function Replay.IsRecording() return Rec ~= nil and Rec.live == true end
