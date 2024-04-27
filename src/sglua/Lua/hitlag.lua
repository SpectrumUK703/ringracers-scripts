local cv_hitlag = CV_RegisterVar({
	name = "hitlag_multiplier",
	defaultvalue = "0",
	flags = CV_FLOAT|CV_NETVAR,
	description = "Multiplier for player hitlag",
	possiblevalue = { MIN = 0, MAX = FRACUNIT*9001 } -- WHAT! NINE THOUSAND!?
})

local cv_tricklag = CV_RegisterVar({
	name = "tricklag_multiplier",
	defaultvalue = "0",
	flags = CV_FLOAT|CV_NETVAR,
	description = "Multiplier for trick hitlag",
	possiblevalue = { MIN = 0, MAX = FRACUNIT*9001 }
})

local cv_hyudorolag = CV_RegisterVar({
	name = "hyudorolag_multiplier",
	defaultvalue = "0",
	flags = CV_FLOAT|CV_NETVAR,
	description = "Multiplier for hyudoro hitlag",
	possiblevalue = { MIN = 0, MAX = FRACUNIT*9001 }
})

local cv_triplag = CV_RegisterVar({
	name = "tripwirelag_multiplier",
	defaultvalue = "0",
	flags = CV_FLOAT|CV_NETVAR,
	description = "Multiplier for tripwire hitlag",
	possiblevalue = { MIN = 0, MAX = FRACUNIT*9001 }
})

local TRICKSTATE_READY = 1
local TRIPSTATE_NONE = 0

local tagged = {}
local tricking = {}

addHook("MobjDamage", function(target, inflictor, source)
	if target.player then tagged[target.player] = true end
	if inflictor and inflictor.player then tagged[inflictor.player] = true end
end, MT_PLAYER)

local function height(thing, tmthing)
	return tmthing.z > thing.z + thing.height or tmthing.z + tmthing.height < thing.z
end

local function droptarget(thing, tmthing)
	if height(thing, tmthing) then return end
	if (thing.target == tmthing or thing.target == tmthing.target) and ((thing.threshold > 0 and tmthing.player) or (not tmthing.player and tmthing.threshold > 0)) then return end
	if thing.health <= 0 or tmthing.health <= 0 then return end
	if tmthing.player and (tmthing.player.hyudorotimer or tmthing.player.justbumped) then return end

	if thing.player then tagged[thing.player] = true end
	if tmthing.player then tagged[tmthing.player] = true end
end
addHook("MobjCollide", droptarget, MT_DROPTARGET)
addHook("MobjMoveCollide", droptarget, MT_DROPTARGET)

local function setlag(p, mult)
	p.mo.hitlag = FixedMul($, mult.value)

	-- handle delayed ring burst. doesn't run if there's zero hitlag
	if p.mo.hitlag == 0 and p.ringburst > 0 then
		P_PlayerRingBurst(p, p.ringburst)
		P_PlayRinglossSound(p.mo, nil)
		p.ringburst = 0
	end
end

addHook("PreThinkFrame", function()
	for p in players.iterate do
		tricking[p] = p.trickpanel == TRICKSTATE_READY
	end
end)

addHook("PostThinkFrame", function()
	for p in players.iterate do
		-- damage hook or items or whatever
		if tagged[p] then
			setlag(p, cv_hitlag)
			tagged[p] = false
		end

		-- tricks
		if tricking[p] and p.trickpanel ~= TRICKSTATE_READY then
			setlag(p, cv_tricklag)
		end

		-- hyudoro
		-- BUG: game writes 14*TICRATE (or 490) to an SINT8, which overflows to -22
		if p.stealingtimer == -22 then
			setlag(p, cv_hyudorolag)
		end

		-- tripwire
		if p.tripwirestate ~= TRIPSTATE_NONE then
			setlag(p, cv_triplag)
		end
	end
end)

addHook("PlayerQuit", function(p)
	-- in a break from tradition, don't leak memory, no matter how small
	tagged[p] = nil
	tricking[p] = nil
end)
