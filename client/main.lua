-- client/main.lua — replay browser, the watch session, and its controls.
--
-- Controls while watching (all game input is disabled, so nothing leaks into
-- the parked ped):
--   SPACE play/pause · ←/→ seek · ↑/↓ speed · Q/E driver · C camera
--   H hide UI · B Rockstar Editor rec/stop · G open Rockstar Editor
--   M mouse for the timeline · BACKSPACE exit

local watching = false
local saved = nil          -- the viewer's ped state, restored on exit
local cursor = false

local function nui(action, data) SendNUIMessage({ action = action, data = data }) end

local function notify(msg, t)
    lib.notify({ title = "Replays", description = msg, type = t or "inform" })
end

-- ── Browser ──────────────────────────────────────────────────────────────────

local function openBrowser()
    if watching then return end
    local res = lib.callback.await("spz-replay:list", false)
    nui("browser", res or { rows = {} })
    SetNuiFocus(true, true)
end

RegisterCommand(Config.Command, openBrowser, false)

RegisterNUICallback("closeBrowser", function(_, cb)
    SetNuiFocus(false, false)
    cb("ok")
end)

RegisterNUICallback("refresh", function(_, cb)
    cb(lib.callback.await("spz-replay:list", false) or { rows = {} })
end)

RegisterNUICallback("delete", function(d, cb)
    cb(lib.callback.await("spz-replay:delete", false, d.id) and true or false)
end)

RegisterNUICallback("watch", function(d, cb)
    local ok, why = lib.callback.await("spz-replay:open", false, d.id)
    if not ok then
        cb({ ok = false, error = why or "Couldn't open that replay." })
        return
    end
    SetNuiFocus(false, false)
    nui("loading", { track = d.track })
    cb({ ok = true })
end)

--- Watch the replay of a race by its race id (spz-leaderboard's race archive).
--- Returns ok, error.
local function watchRace(raceId)
    if watching then return false, "Already watching a replay." end
    local ok, res = lib.callback.await("spz-replay:openByRace", false, raceId)
    if not ok then return false, res or "No replay stored for that race." end
    nui("loading", { track = res })
    return true
end
exports("WatchRace", watchRace)

-- ── Session ──────────────────────────────────────────────────────────────────

local function parkPed(at)
    local ped = PlayerPedId()
    saved = { coords = GetEntityCoords(ped), heading = GetEntityHeading(ped), veh = GetVehiclePedIsIn(ped, false) }
    -- Any other car they're driving (vMenu, etc.) is deleted too, like /dv.
    -- The spz-vehicles car was already despawned by the server.
    if saved.veh ~= 0 and DoesEntityExist(saved.veh) and GetPedInVehicleSeat(saved.veh, -1) == ped then
        NetworkRequestControlOfEntity(saved.veh)
        local deadline = GetGameTimer() + 1000
        while not NetworkHasControlOfEntity(saved.veh) and GetGameTimer() < deadline do Wait(0) end
        SetEntityAsMissionEntity(saved.veh, true, true)
        DeleteVehicle(saved.veh)
    elseif saved.veh ~= 0 then
        TaskLeaveVehicle(ped, saved.veh, 16)
    end
    saved.veh = 0
    Wait(0)
    SetEntityCoords(ped, at.x, at.y, at.z + 2.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityInvincible(ped, true)
end

local function restorePed()
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)
    if saved then
        SetEntityCoords(ped, saved.coords.x, saved.coords.y, saved.coords.z, false, false, false, false)
        SetEntityHeading(ped, saved.heading)
    end
    saved = nil
end

-- ── Rockstar Editor ──────────────────────────────────────────────────────────
-- B starts / stops a Rockstar Editor clip of the replay (the game records its
-- own state, so the replay UI never ends up in the clip). G saves any running
-- clip, leaves the replay and opens the Rockstar Editor.
local recStart = nil

local function recToggle()
    if IsRecording() then
        StopRecordingAndSaveClip()
        recStart = nil
        notify("Clip saved to the Rockstar Editor.", "success")
    else
        StartRecording(1)
        recStart = GetGameTimer()
        notify("Recording a Rockstar Editor clip. B to stop and save.", "inform")
    end
end

local function saveRecording()
    if IsRecording() then
        StopRecordingAndSaveClip()
        notify("Clip saved to the Rockstar Editor.", "success")
    end
    recStart = nil
end

local stop

local function openEditor()
    saveRecording()
    stop()
    -- Let the camera, cars and bucket switch settle before the editor loads.
    SetTimeout(600, function() ActivateRockstarEditor() end)
end

stop = function()
    if not watching then return end
    saveRecording()
    watching = false
    Cams.Stop()
    Play.Unload()
    restorePed()
    DisplayRadar(true)
    if cursor then SetNuiFocus(false, false); cursor = false end
    nui("player", { visible = false })
    lib.callback.await("spz-replay:close", false)
end

local function pushHud(s)
    local m = Play.metas[Play.target] or {}
    nui("player", {
        visible  = true,
        t        = Play.t,
        duration = Play.duration,
        paused   = Play.paused,
        speed    = Config.Speeds[Play.speedIdx],
        camera   = Cams.Name(),
        track    = Play.row.track,
        raceType = Play.row.race_type,
        laps     = Play.row.laps,
        carClass = Play.row.car_class,
        target   = {
            name = m.name, crew = m.crew, nation = m.nation, number = m.number, car = m.label,
            pos = s and s.pos or 0, lap = s and s.lap or 0, speed = s and math.floor(s.s) or 0,
            finalPos = m.pos, time = m.time, dnf = m.dnf,
        },
        count    = #Play.metas,
        rec      = recStart and (GetGameTimer() - recStart) or nil,
        board    = Play.Board(),
    })
end

local function run()
    local last = GetGameTimer()
    local lastHud = 0
    local T0 = Play.tracks[Play.target]
    Cams.Start(vector3(T0.x[1], T0.y[1], T0.z[1]))
    DisplayRadar(false)

    while watching do
        local now = GetGameTimer()
        -- Frame time as a float: integer ms deltas stutter at high framerates.
        local dt = math.min(GetFrameTime(), 0.1) * 1000
        last = now

        DisableAllControlActions(0)
        EnableControlAction(0, 245, true)   -- chat (T)
        EnableControlAction(0, 249, true)   -- push to talk

        if IsDisabledControlJustPressed(0, 22) then Play.paused = not Play.paused   -- SPACE
            if not Play.paused and Play.t >= Play.duration then Play.t = 0 end
        end
        if IsDisabledControlJustPressed(0, 174) then Play.Seek(Play.Goal() - Config.SeekSec * 1000) end   -- ←
        if IsDisabledControlJustPressed(0, 175) then Play.Seek(Play.Goal() + Config.SeekSec * 1000) end   -- →
        if IsDisabledControlJustPressed(0, 172) then Play.speedIdx = math.min(#Config.Speeds, Play.speedIdx + 1) end -- ↑
        if IsDisabledControlJustPressed(0, 173) then Play.speedIdx = math.max(1, Play.speedIdx - 1) end             -- ↓
        if IsDisabledControlJustPressed(0, 44) and Play.Switch(-1) then Play.lastSeg = nil; Cams.OnTargetChanged(GetEntityCoords(Play.cars[Play.target])) end   -- Q
        if IsDisabledControlJustPressed(0, 38) and Play.Switch(1) then Play.lastSeg = nil; Cams.OnTargetChanged(GetEntityCoords(Play.cars[Play.target])) end    -- E
        if IsDisabledControlJustPressed(0, 26) then Cams.Cycle(1) end                                 -- C
        if IsDisabledControlJustPressed(0, 74) then nui("recordView", {}) end                         -- H
        if IsDisabledControlJustPressed(0, 244) then                                                  -- M
            cursor = not cursor
            SetNuiFocus(cursor, cursor)
            SetNuiFocusKeepInput(cursor)
        end
        if IsDisabledControlJustPressed(0, 29) then recToggle() end                                   -- B
        if IsDisabledControlJustPressed(0, 47) then openEditor(); break end                           -- G
        if IsDisabledControlJustPressed(0, 177) then stop(); break end                               -- BACKSPACE

        local s = Play.Step(dt)
        if Play.cutNow then Play.cutNow = false; Cams.Snap() end
        Cams.Update(Play.cars[Play.target], Play.tracks[Play.target], Play.target, dt / 1000)

        if now - lastHud > 50 then
            lastHud = now
            pushHud(s)
        end
        Wait(0)
    end
end

RegisterNetEvent("spz-replay:data", function(row, blob)
    if watching then return end
    local ok, tracks = pcall(Codec.Decode, blob or "")
    if not ok or not tracks or #tracks == 0 then
        nui("player", { visible = false })
        notify("That replay couldn't be read.", "error")
        lib.callback.await("spz-replay:close", false)
        return
    end
    local first = tracks[1]
    parkPed(vector3(first.x[1], first.y[1], first.z[1]))
    -- Let the map stream in around the start before the cars appear.
    SetFocusPosAndVel(first.x[1], first.y[1], first.z[1], 0.0, 0.0, 0.0)
    Wait(800)
    if not Play.Load(row, tracks) then
        Play.Unload()
        restorePed()
        ClearFocus()
        nui("player", { visible = false })
        notify("None of the cars in that replay could be loaded.", "error")
        lib.callback.await("spz-replay:close", false)
        return
    end
    watching = true
    CreateThread(run)
end)

-- Timeline: click/drag to seek, buttons for the rest (mouse mode, M).
RegisterNUICallback("seek", function(d, cb)
    if watching and tonumber(d.t) then Play.Seek(tonumber(d.t)) end
    cb("ok")
end)
RegisterNUICallback("control", function(d, cb)
    if watching then
        if d.op == "toggle" then Play.paused = not Play.paused
        elseif d.op == "camera" then Cams.Cycle(1)
        elseif d.op == "next" and Play.Switch(1) then Play.lastSeg = nil; Cams.OnTargetChanged(GetEntityCoords(Play.cars[Play.target]))
        elseif d.op == "prev" and Play.Switch(-1) then Play.lastSeg = nil; Cams.OnTargetChanged(GetEntityCoords(Play.cars[Play.target]))
        elseif d.op == "target" and Play.cars[tonumber(d.id)] then Play.target = tonumber(d.id); Play.lastSeg = nil; Cams.OnTargetChanged(GetEntityCoords(Play.cars[Play.target]))
        elseif d.op == "record" then recToggle()
        elseif d.op == "editor" then openEditor()
        elseif d.op == "exit" then stop() end
    end
    cb("ok")
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() or not watching then return end
    if IsRecording() then StopRecordingAndSaveClip() end
    watching = false
    Cams.Stop()
    Play.Unload()
    restorePed()
    DisplayRadar(true)
    SetNuiFocus(false, false)
end)
