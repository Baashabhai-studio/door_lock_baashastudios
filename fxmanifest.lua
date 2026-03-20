fx_version 'cerulean'
game 'gta5'
author 'BaashaBhai'
version '1.2.0'
description 'BaashaBhai Door Lock — QBCore & ESX | Luxury Security System'

-- Set Config.Framework in config.lua to 'qbcore' or 'esx'
-- then make sure the matching framework resource is started first.

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/main.js',
}

shared_scripts {
    'config.lua',
}

client_scripts {
    'bridge/client.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server.lua',
    'server/main.lua',
}

lua54 'yes'
