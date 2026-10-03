-- config.lua — spz-replay

Config = {}

Config.Command     = "replays"   -- opens the replay browser
Config.IntervalMs  = 100         -- sample rate while a race is LIVE (10 Hz)
Config.MinRaceSec  = 15          -- shorter races (aborts, instant DNFs) are not saved
Config.MaxRaceMin  = 30          -- recording stops past this, so a stuck race can't grow forever
Config.KeepReplays = 50          -- newest N replays kept in the DB; older rows are deleted
Config.ListLimit   = 30          -- rows shown in the browser
Config.DeleteAce   = "spz.admin" -- may delete replays from the browser

-- Playback
Config.Speeds      = { 0.25, 0.5, 1.0, 2.0, 4.0 }
Config.SeekSec     = 5           -- arrow-key jump
Config.HideAfterFinishMs = 2500  -- a car that stops being recorded (finished) disappears after this

-- TV cameras are generated along the watched car's own line: one every
-- TvSpacing metres, TvSide metres off to alternating sides, TvHeight up.
Config.TvSpacing = 110.0
Config.TvSide    = 13.0
Config.TvHeight  = 4.5
