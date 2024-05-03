local cv_respawnspin = CV_RegisterVar({
    name = "respawnspin",
    defaultvalue = "Off",
    possiblevalue = CV_OnOff,
    flags = CV_NETVAR,
    description = "Allow spinout during respawn",
})

addHook("PlayerThink", function(player)
    local respawn = player.respawn.state

    if cv_respawnspin.value == 0 and respawn ~= 0 then
        player.spinouttimer = 0
    end

    if respawn then
        if player.flashing_store then
            player.flashing = player.flashing_store
        else
            player.flashing_store = player.flashing
        end
    else
        player.flashing_store = nil
    end
end)
