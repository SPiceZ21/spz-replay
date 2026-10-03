-- shared/codec.lua — replay frame format (server encodes, client decodes).
--
-- A replay is one text blob: racer tracks joined by "|". A track is frames
-- joined by ";", a frame is 10 comma-separated integers:
--
--   t     ms since the race went LIVE
--   x y z position in centimetres
--   p r h pitch / roll / heading in tenths of a degree
--   s     speed, km/h
--   pos   race position, lap  current lap
--
-- The first frame of a track is absolute; every later frame stores the
-- difference from the previous one for t..h (heading wrapped to ±180°), and
-- s / pos / lap as-is. Zeros are written as nothing ("100,12,,,,,3,182,2,1"),
-- which on a racing line is most fields. MariaDB COMPRESS() does the rest.

Codec = {}

local floor = math.floor
local function round(v) return floor(v + 0.5) end
local function wrap(d) -- tenths of a degree into -1800..1800
    d = d % 3600
    if d > 1800 then d = d - 3600 end
    return d
end
local function f(v) return v == 0 and "" or tostring(v) end

--- frames: list of { t, x, y, z, p, r, h, s, pos, lap } in real units
--- (metres, degrees, km/h). Returns the encoded track string.
function Codec.EncodeTrack(frames)
    local out, prev = {}, nil
    for i, fr in ipairs(frames) do
        local q = {
            round(fr.t), round(fr.x * 100), round(fr.y * 100), round(fr.z * 100),
            round(fr.p * 10), round(fr.r * 10), round(fr.h * 10) % 3600,
            round(fr.s), fr.pos or 0, fr.lap or 0,
        }
        if not prev then
            out[i] = table.concat(q, ",")
        else
            out[i] = table.concat({
                f(q[1] - prev[1]), f(q[2] - prev[2]), f(q[3] - prev[3]), f(q[4] - prev[4]),
                f(wrap(q[5] - prev[5])), f(wrap(q[6] - prev[6])), f(wrap(q[7] - prev[7])),
                f(q[8]), f(q[9]), f(q[10]),
            }, ",")
        end
        prev = q
    end
    return table.concat(out, ";")
end

function Codec.Encode(tracks)
    local parts = {}
    for i, frames in ipairs(tracks) do parts[i] = Codec.EncodeTrack(frames) end
    return table.concat(parts, "|")
end

--- Decodes one track into parallel arrays (cheap to binary-search and lerp):
--- { t = {}, x = {}, y = {}, z = {}, p = {}, r = {}, h = {}, s = {}, pos = {}, lap = {} }
--- in real units again.
function Codec.DecodeTrack(str)
    local T = { t = {}, x = {}, y = {}, z = {}, p = {}, r = {}, h = {}, s = {}, pos = {}, lap = {} }
    local acc = nil
    local n = 0
    for frame in (str .. ";"):gmatch("([^;]*);") do
        if frame ~= "" then
            local v, k = {}, 0
            for field in (frame .. ","):gmatch("([^,]*),") do
                k = k + 1
                v[k] = tonumber(field) or 0
            end
            if not acc then
                acc = { v[1], v[2], v[3], v[4], v[5], v[6], v[7] }
            else
                for j = 1, 7 do acc[j] = acc[j] + v[j] end
            end
            n = n + 1
            T.t[n] = acc[1]
            T.x[n], T.y[n], T.z[n] = acc[2] / 100, acc[3] / 100, acc[4] / 100
            T.p[n], T.r[n], T.h[n] = acc[5] / 10, acc[6] / 10, (acc[7] % 3600) / 10
            T.s[n], T.pos[n], T.lap[n] = v[8], v[9], v[10]
        end
    end
    T.n = n
    return T
end

function Codec.Decode(blob)
    local tracks = {}
    for str in (blob .. "|"):gmatch("([^|]*)|") do tracks[#tracks + 1] = Codec.DecodeTrack(str) end
    return tracks
end
