-- LIBSG v2: Mystery of the Missing Lua API

-- returns viewx, viewy, viewz, viewangle, aimingangle, viewroll
local cv_tilting
rawset(_G, "SG_GetViewVars", function(v, p, c)
	if not cv_tilting then cv_tilting = CV_FindVar("tilting") end
	local roll = p.viewrollangle + (cv_tilting.value and not (p.spectator --[[or c.freecam]]) and p.tilt or 0)

	if p.awayviewtics then
		local mo = p.awayviewmobj
		return mo.x, mo.y, mo.z, mo.angle, mo.pitch, roll
	elseif c.chase then
		return c.x, c.y, c.z + c.height/2, c.angle, c.aiming, roll
	elseif p.mo then
		return p.mo.x, p.mo.y, p.viewz, p.mo.angle, p.aiming, roll
	end
end)

local fovvars
local function R_FOV(num)
	if not fovvars then
		fovvars = { [0] = CV_FindVar("fov"), CV_FindVar("fov2"), CV_FindVar("fov3"), CV_FindVar("fov4") }
	end
	return fovvars[num].value
end
local function AngleDeltaSigned(a1, a2)
	return a1 - a2
end

// This version of the function was prototyped in Lua by Nev3r ... a HUGE thank you goes out to them!
-- if only it was exposed
local baseFov = 90*FRACUNIT
local BASEVIDWIDTH = 320
local BASEVIDHEIGHT = 200
rawset(_G, "K_ObjectTracking", function(v, p, c, point, reverse)
	local cameraNum = c.pnum - 1
	local viewx, viewy, viewz, viewangle, aimingangle, viewroll = SG_GetViewVars(v, p, c)

	// Initialize defaults
	local result = {}
	result.x, result.y = 0, 0
	result.scale = FRACUNIT
	result.onScreen = false

	// Take the view's properties as necessary.
	local viewpointAngle, viewpointAiming, viewpointRoll
	if reverse then
		viewpointAngle = viewangle + ANGLE_180
		viewpointAiming = InvAngle(aimingangle)
		viewpointRoll = viewroll
	else
		viewpointAngle = viewangle
		viewpointAiming = aimingangle
		viewpointRoll = InvAngle(viewroll)
	end

	// Calculate screen size adjustments.
	local screenWidth = v.width()/v.dupx()
	local screenHeight = v.height()/v.dupy()

	-- what's the difference between this and r_splitscreen?
	-- future G: seems to alternate between view count and view number depending on where you are in the codebase
	-- may i interest the Krew in stplyrnum? :^)
	if splitscreen >= 2 then
		// Half-wide screens
		screenWidth = $ >> 1
	end

	if splitscreen >= 1 then
		// Half-tall screens
		screenHeight = $ >> 1
	end

	local screenHalfW = (screenWidth >> 1) << FRACBITS
	local screenHalfH = (screenHeight >> 1) << FRACBITS

	// Calculate FOV adjustments.
	local fovDiff = R_FOV(cameraNum) - baseFov
	local fov = ((baseFov - fovDiff) / 2) - (p.fovadd / 2)
	local fovTangent = tan(FixedAngle(fov))

	if splitscreen == 1 then
		// Splitscreen FOV is adjusted to maintain expected vertical view
		fovTangent = 10*fovTangent/17
	end

	local fg = (screenWidth >> 1) * fovTangent

	// Determine viewpoint factors.
	local h = R_PointToDist2(point.x, point.y, viewx, viewy)
	local da = AngleDeltaSigned(viewpointAngle, R_PointToAngle2(viewx, viewy, point.x, point.y))
	local dp = AngleDeltaSigned(viewpointAiming, R_PointToAngle2(0, 0, h, viewz))

	if reverse then da = -da end

	// Set results relative to top left!
	result.x = FixedMul(tan(da), fg)
	result.y = FixedMul((tan(viewpointAiming) - FixedDiv((point.z - viewz), 1 + FixedMul(cos(da), h))), fg)

	result.angle = da
	result.pitch = dp
	result.fov = fg

	// Rotate for screen roll...
	if viewpointRoll then
		local tempx = result.x
		result.x = FixedMul(cos(viewpointRoll), tempx) - FixedMul(sin(viewpointRoll), result.y)
		result.y = FixedMul(sin(viewpointRoll), tempx) + FixedMul(cos(viewpointRoll), result.y)
	end

	// Flipped screen?
	if encoremode then result.x = -result.x end

	// Center results.
	result.x = $ + screenHalfW
	result.y = $ + screenHalfH

	result.scale = FixedDiv(screenHalfW, h+1)

	result.onScreen = not ((abs(da) > ANG60) or (abs(AngleDeltaSigned(viewpointAiming, R_PointToAngle2(0, 0, h, (viewz - point.z)))) > ANGLE_45))

	// Cheap dirty hacks for some split-screen related cases
	if result.x < 0 or result.x > (screenWidth << FRACBITS) then
		result.onScreen = false
	end

	if result.y < 0 or result.y > (screenHeight << FRACBITS) then
		result.onScreen = false
	end

	// adjust to non-green-resolution screen coordinates
	result.x = $ - ((v.width()/v.dupx()) - BASEVIDWIDTH)<<(FRACBITS-(splitscreen >= 2 and 2 or 1))
	result.y = $ - ((v.height()/v.dupy()) - BASEVIDHEIGHT)<<(FRACBITS-(splitscreen >= 1 and 2 or 1))
	return result
end)
