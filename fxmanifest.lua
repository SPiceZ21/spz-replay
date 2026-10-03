fx_version 'cerulean'
game 'gta5'

name 'spz-replay'
description 'SPiceZ Race Replays — records every race server-side, stores it compressed in the DB, and plays it back with TV / chase / heli / bonnet / wheel / free cameras, driver switching and a clean record view.'
version '1.1.0'
author 'SPiceZ-Core'
lua54 'yes'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
  'shared/codec.lua',
}

client_scripts {
  'client/cameras.lua',
  'client/player.lua',
  'client/main.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/recorder.lua',
  'server/main.lua',
}

ui_page 'ui/index.html'

files {
  'ui/index.html',
  'ui/style.css',
  'ui/app.js',
  'ui/fonts/*.ttf',
}

dependencies {
  'ox_lib',
  'oxmysql',
  'spz-core',
  'spz-races',
  'spz-vehicles',
}
