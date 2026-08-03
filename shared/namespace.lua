--- nxc_interact — reusable interaction workflows.
---
--- Doing something that takes time: an animation, a prop in your hands, a
--- progress bar, and an outcome. Every job, business, and crime resource needs
--- this, and without it each one writes its own — badly, differently, and with
--- its own cancellation bugs.
---
--- **A COMPLETED ANIMATION IS NOT A COMPLETED ACTION.** The client plays the
--- animation and reports that it finished. That report is a claim by a machine
--- the player controls, exactly like a target selection or a reported position.
---
--- So the server starts the workflow, knows when it started, enforces the
--- declared duration against its own clock, and refuses a completion that
--- arrived too early. A player who removes the animation entirely still has to
--- wait, because the wait is the thing being enforced rather than the animation.
---
--- **IT OWNS NO ITEMS AND NO MONEY.** Consumption and reward are *requests* to
--- whichever resource owns those, and this resource does not become a second
--- inventory. Nothing owns them yet, so those requests fail closed.

NxcInteract = NxcInteract or {}

NxcInteract.RESOURCE = 'nxc_interact'

NxcInteract.VERSION = (type(GetResourceMetadata) == 'function'
    and GetResourceMetadata(GetCurrentResourceName(), 'version', 0))
    or '0.0.0-test'

NxcInteract.CONTRACT_VERSION = 1

--- The nxc_lib contract this resource needs.
---
--- Failing at startup with a sentence naming the cause beats failing later at
--- whichever line first reached a function that is not there.
local REQUIRED_LIB_CONTRACT = 3

if type(Nxc) ~= 'table' then
    error('nxc_interact requires nxc_lib. Load its shared modules with @nxc_lib/... '
        .. 'entries in shared_scripts: a dependency orders startup and shares no '
        .. 'code, because every resource has its own Lua state.', 0)
end

if (Nxc.CONTRACT_VERSION or 0) < REQUIRED_LIB_CONTRACT then
    error(('nxc_interact requires nxc_lib contract %d and found %d. Install a whole '
        .. 'compatibility set; mixing versions is unsupported.')
        :format(REQUIRED_LIB_CONTRACT, Nxc.CONTRACT_VERSION or 0), 0)
end

return NxcInteract
