-- client/recorder.lua — samples MY race car for the replay.
--
-- While the race is LIVE and I'm in it, my car's exact pose is sampled every
-- Config.IntervalMs and sent to the server once a second (server/recorder.lua
-- validates and stores it). Times are ms since this client saw the race go
-- LIVE, so every racer's track shares the same zero give or take a ping.

local liveAt = nil
local warned = false

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if value == "LIVE" then liveAt = GetGameTimer() end
end)
if GlobalState.raceState == "LIVE" then liveAt = GetGameTimer() end

CreateThread(function()
    local buf, sentMeta, raceId, lastFlush = {}, false, nil, 0
    local carMeta = false   -- read from the car while I'm in it, sent with the first batch
    local sending, sent = false, 0

    local function flush()
        if #buf == 0 or not raceId then return end
        -- false, never nil: a nil in the middle of an event's arguments can
        -- make FiveM drop the arguments after it (the frames).
        local meta = false
        if not sentMeta and carMeta then
            meta = carMeta
            sentMeta = true
        end
        TriggerServerEvent("spz-replay:frames", raceId, meta, buf)
        sent = sent + #buf
        buf = {}
        lastFlush = GetGameTimer()
    end

    while true do
        local st = LocalPlayer.state
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        local rid = GlobalState.replayRaceId
        if liveAt and GlobalState.raceState == "LIVE" and st.inRace and veh ~= 0 and rid then
            if rid ~= raceId then buf, sentMeta, raceId, carMeta, sent = {}, false, rid, false, 0 end
            if not sending then
                sending = true
                print(("^2[spz-replay] recording my car for race %s^7"):format(tostring(rid)))
            end
            if not carMeta then
                local c1, c2 = GetVehicleColours(veh)
                carMeta = { model = GetEntityModel(veh), c1 = c1, c2 = c2, plate = GetVehicleNumberPlateText(veh) }
            end
            local c, rot = GetEntityCoords(veh), GetEntityRotation(veh, 2)
            buf[#buf + 1] = {
                t = GetGameTimer() - liveAt,
                x = c.x, y = c.y, z = c.z, p = rot.x, r = rot.y, h = rot.z,
                s = GetEntitySpeed(veh) * 3.6,
                pos = tonumber(st.racePosition) or 0, lap = tonumber(st.raceLap) or 0,
            }
            if GetGameTimer() - lastFlush >= 1000 or #buf >= 30 then flush() end
            Wait(Config.IntervalMs)
        else
            flush()   -- finished / left: send what's left
            if sending then
                sending = false
                print(("^2[spz-replay] stopped recording: sent %d frames (%.0fs)^7"):format(sent, sent * Config.IntervalMs / 1000))
            elseif liveAt and GlobalState.raceState == "LIVE" and st.inRace and veh ~= 0 and not rid then
                -- In a live race but the server never opened a recording.
                if not warned then
                    warned = true
                    print("^3[spz-replay] race is LIVE but no replayRaceId: is spz-replay running on the server?^7")
                end
            end
            Wait(250)
        end
    end
end)
