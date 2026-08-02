fx_version 'cerulean'
game 'gta5'

author 'The Nexus Core Framework team'
description 'Reusable interaction workflow orchestration: animations, props, progress, skill checks, cancellation, cleanup.'
version '0.1.0'

shared_scripts {
    'shared/*.lua',
}

client_scripts {
    'client/*.lua',
}

server_scripts {
    'server/*.lua',
}

files {
    'locales/*.json',
}

dependencies {
    'nxc_lib',
    'nxc_target',
    'nxc_ui',
}
