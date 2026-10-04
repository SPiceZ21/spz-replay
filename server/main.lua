-- server/main.lua — replay storage, browser callbacks, playback buckets.

Replay = Replay or {}

-- ── Storage ──────────────────────────────────────────────────────────────────

function Replay.Save(r)
    local ok, err = pcall(function()
        MySQL.insert.await([[
            INSERT INTO race_replays
                (race_id, track, track_id, race_type, laps, car_class, duration_ms, interval_ms,
                 racer_count, winner, racers, frames, size_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COMPRESS(?), ?)
            ON DUPLICATE KEY UPDATE race_id = race_id
        ]], {
            r.raceId, r.track, r.trackId, r.raceType, r.laps, r.carClass, math.floor(r.duration),
            Config.IntervalMs, #r.racers, r.winner, json.encode(r.racers), r.blob, #r.blob,
        })
        -- Keep only the newest KeepReplays rows.
        MySQL.update.await([[
            DELETE FROM race_replays WHERE id NOT IN (
                SELECT id FROM (SELECT id FROM race_replays ORDER BY id DESC LIMIT ?) keep_rows
            )
        ]], { Config.KeepReplays })
    end)
    if ok then
        print(("^2[spz-replay] saved %s: %d racers, %.1fs, %d KB raw^7"):format(
            r.track, #r.racers, r.duration / 1000, math.floor(#r.blob / 1024)))
    else
        print(("^1[spz-replay] save failed: %s^7"):format(tostring(err)))
    end
end

-- ── Who may watch ────────────────────────────────────────────────────────────

local Watching = {}   -- [src] = { bucket, back }

local function busy(src)
    local st = Player(src).state
    if st.inRace or st.inQueue then return "You're in a race or race queue." end
    if st.inMinigame and st.inMinigame ~= "replay" then return "Leave your minigame first." end
    local ok, tt = pcall(function() return exports["spz-races"]:IsInTimeTrial(src) end)
    if ok and tt then return "Leave your time trial first." end
    return nil
end

local function canDelete(src)
    local ok, allowed = pcall(function() return exports["spz-core"]:HasPermission(src, Config.DeleteAce) end)
    return (ok and allowed == true) or IsPlayerAceAllowed(src, Config.DeleteAce)
end

-- ── Browser ──────────────────────────────────────────────────────────────────

local function analytics(feature)
    if GetResourceState("spz-analytics") == "started" then
        pcall(function() exports["spz-analytics"]:Track(feature) end)
    end
end

lib.callback.register("spz-replay:list", function(src)
    analytics("replays_browser")
    local rows = MySQL.query.await([[
        SELECT id, track, race_type, laps, car_class, duration_ms, racer_count, winner,
               size_bytes, UNIX_TIMESTAMP(created_at) AS created
        FROM race_replays ORDER BY id DESC LIMIT ?
    ]], { Config.ListLimit }) or {}
    return { rows = rows, canDelete = canDelete(src), recording = Replay.IsRecording() }
end)

lib.callback.register("spz-replay:delete", function(src, id)
    if not canDelete(src) then return false end
    MySQL.update.await("DELETE FROM race_replays WHERE id = ?", { tonumber(id) })
    if GetResourceState("spz-analytics") == "started" then
        pcall(function() exports["spz-analytics"]:AdminAction(src, "replay_delete", "replay #" .. tostring(id)) end)
    end
    return true
end)

-- Start watching: private bucket, then the replay itself as a latent event
-- (a few hundred KB; latent events stream it without a hitch).
-- `where` is "id = ?" (browser) or "race_id = ?" (leaderboard race archive).
local function openReplay(src, where, key)
    if Watching[src] then return false, "Already watching." end
    local why = busy(src)
    if why then return false, why end

    local row = MySQL.single.await(([[
        SELECT id, track, race_type, laps, car_class, duration_ms, interval_ms, winner, racers,
               CONVERT(UNCOMPRESS(frames) USING utf8mb4) AS frames, UNIX_TIMESTAMP(created_at) AS created
        FROM race_replays WHERE %s
    ]]):format(where), { key })
    if not row or not row.frames then return false, "No replay stored for that race." end

    -- Same as /dv: the player's spawned car goes before they leave for the
    -- replay bucket, instead of being left parked in the world.
    pcall(function() exports["spz-vehicles"]:DespawnVehicle(src) end)

    local bucket = exports["spz-core"]:CreateBucket("replay")
    SetRoutingBucketPopulationEnabled(bucket, false)
    Watching[src] = { bucket = bucket, back = GetPlayerRoutingBucket(src) }
    exports["spz-core"]:AssignPlayerToBucket(src, bucket)
    Player(src).state:set("inMinigame", "replay", true)

    local frames = row.frames
    row.frames = nil
    TriggerLatentClientEvent("spz-replay:data", src, 400000, row, frames)
    return true, row.track
end

lib.callback.register("spz-replay:open", function(src, id)
    analytics("replay_watch")
    return openReplay(src, "id = ?", tonumber(id))
end)

lib.callback.register("spz-replay:openByRace", function(src, raceId)
    analytics("replay_watch")
    return openReplay(src, "race_id = ?", tostring(raceId))
end)

--- Which of these race ids have a stored replay. Used by spz-leaderboard to
--- badge its race archive. Returns { [raceId] = true }.
local function replayIdsFor(raceIds)
    local out = {}
    if type(raceIds) ~= "table" or #raceIds == 0 then return out end
    local ids = {}
    for i = 1, math.min(#raceIds, 100) do ids[i] = tostring(raceIds[i]) end
    local marks = string.rep("?,", #ids):sub(1, -2)
    local rows = MySQL.query.await("SELECT race_id FROM race_replays WHERE race_id IN (" .. marks .. ")", ids) or {}
    for _, r in ipairs(rows) do out[r.race_id] = true end
    return out
end
exports("HasReplays", replayIdsFor)
lib.callback.register("spz-replay:hasReplays", function(_, raceIds) return replayIdsFor(raceIds) end)

local function stopWatching(src)
    local w = Watching[src]
    if not w then return end
    Watching[src] = nil
    if GetPlayerName(src) then
        exports["spz-core"]:AssignPlayerToBucket(src, w.back or 0)
        Player(src).state:set("inMinigame", nil, true)
    end
    pcall(function() exports["spz-core"]:DeleteBucket(w.bucket) end)
end

lib.callback.register("spz-replay:close", function(src) stopWatching(src); return true end)
AddEventHandler("playerDropped", function() stopWatching(source) end)
AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for src in pairs(Watching) do stopWatching(src) end
end)
