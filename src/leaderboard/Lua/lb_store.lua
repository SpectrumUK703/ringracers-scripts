-- This file handles the storage and related netvars of the leaderboard

---- Imported functions ----

-- lb_common.lua
local stat_t = lb_stat_t
local lbComp = lb_comp
local score_t = lb_score_t
local player_t = lb_player_t
local mapChecksum = lb_map_checksum
local mapnumFromExtended = lb_mapnum_from_extended
local ticsToTime = lb_TicsToTime

----------------------------

local LEADERBOARD_FILE = "leaderboard.sav2"
local LEADERBOARD_FILE_OLD = "leaderboard.txt"
local COLDSTORE_FILE = "leaderboard.coldstore.sav2"
local LEADERBOARD_VERSION = 1
local INDEX_VERSION = 1

local cv_directory = CV_RegisterVar({
	name = "lb_store_directory",
	flags = CV_NETVAR,
	defaultvalue = "my_leaderboard",
})

-- Livestore are new records nad records loaded from leaderboard.txt file
local LiveStore = {}

-- next available ID for records
local NextID = 1

-- which records are waiting to be written to the coldstore
local Dirty = {}

-- parse score function
local parseScore

local MSK_SPEED = 0xF0
local MSK_WEIGHT = 0xF
local function stat_str(stat)
	if stat then
		return string.format("%d%d", (stat & MSK_SPEED) >> 4, stat & MSK_WEIGHT)
	end

	return "0"
end

local function isSameRecord(a, b, modeSep)
	if (a.flags & modeSep) ~= (b.flags & modeSep)
	or #a.players ~= #b.players then return false end
	for i = 1, #a.players do
		if a.players[i].name ~= b.players[i].name then return false end
	end
	return true
end

-- insert or replace the score in dest
-- returns true if inserted, false if (maybe) replaced
local function insertOrReplace(dest, score, modeSep)
	for i, record in ipairs(dest) do
		if isSameRecord(record, score, modeSep) then
			if lbComp(score, record) then
				dest[i] = score
				score.id = record.id
			end
			return false
		end
	end

	table.insert(dest, score)
	return true
end

local function READ8(f)
	return f:read(1):byte()
end
local function READ16(f)
	local nl, nh = f:read(2):byte(1, 2)
	return nl | (nh << 8)
end
local function READNUM(f)
	local num = 0
	for i = 0, 7*(5-1), 7 do
		local c = f:read(1):byte()
		num = num | (c & 0x7f) << i
		if not (c & 0x80) then return num end
	end
	error("Overlong number at "..f:seek("cur", 0), 2)
end
local function READSTR(f)
	local len = f:read(1):byte()
	return f:read(len) or ""
end
local function READGHOST(f)
	local ll, lh = f:read(2):byte(1, 2)
	return f:read(ll | (lh << 8)) or ""
end

-- write functions go into a string buffer, not a file
-- if something goes wrong, you won't end up with a half-written file
local tins = table.insert
local function WRITE8(f, num)
	tins(f, string.char(num))
end
local function WRITE16(f, num)
	tins(f, string.char(num & 0xffff00ff, (num & 0xffffff00) >> 8))
end
local function WRITENUM(f, num)
	if num < 0 then
		error("Cannot write negative numbers", 2)
	end
	repeat
		tins(f, string.char((num >= 128 and 0x80 or 0x00) | (num & 0x7f)))
		num = num >> 7
	until not num
end
local function WRITESTR(f, str)
	if #str > 255 then
		error("String too long", 2)
	end
	tins(f, string.char(#str))
	tins(f, str)
end
local function WRITEGHOST(f, str) -- more like WRITELONGSTR but eh
	if #str > 65535 then
		error("String too long", 2)
	end
	tins(f, string.char(#str & 0xff, #str >> 8))
	tins(f, str)
end

-- a file that is actually reading from a string
local function FakeReader(str)
	return {
		str, 1,
		read = function(self, num)
			if not num then return #self[1] > self[2] and "" or nil end
			local s = self[1]:sub(self[2], self[2]+num-1)
			self[2] = $ + num
			return s
		end,
		close = do end
	}
end

local function postfix(filename, str)
	local i = #filename - filename:reverse():find(".", 1, true)
	return filename:sub(1, i)..str..filename:sub(i+1)
end

local function write_segmented(filename, data)
	local fnum = 0
	for i = 1, #data, 1048576 do
		local out = assert(
			io.open(postfix(filename, "_"..fnum), "wb"),
			"Failed to open file for writing: "..filename
		)
		out:write(data:sub(i, i+1048575))
		out:close()
		fnum = $ + 1
	end
	repeat
		local old = io.open(postfix(filename, "_"..fnum), "rb")
		if old then
			old:close()
			old = io.open(postfix(filename, "_"..fnum), "wb")
			old:close()
			fnum = $ + 1
		end
	until not old
end

local function read_segmented(filename)
	local fnum = 0
	local data = {}
	while true do
		local f = io.open(postfix(filename, "_"..fnum), "rb")
		if not (f and f:read(0)) then
			break
		end
		tins(data, f:read("*a"))
		f:close()
		fnum = $ + 1
	end
	data = table.concat($)
	return #data and FakeReader(data) or nil
end

local function writeMapStore(mapnum, records, withghosts)
	local f = { "LEADERBOARD", string.char(LEADERBOARD_VERSION) }
	WRITE16(f, tonumber(mapChecksum(mapnum) or "0", 16))
	WRITENUM(f, #records)
	for _, record in ipairs(records) do
		WRITENUM(f, record.id)
		WRITENUM(f, record.flags)
		WRITENUM(f, record.time)
		WRITE8(f, #record.splits)
		for _, v in ipairs(record.splits) do
			WRITENUM(f, v)
		end
		WRITE8(f, #record.players)
		for _, p in ipairs(record.players) do
			WRITESTR(f, p.name)
			WRITESTR(f, p.skin)
			WRITE8(f, p.color)
			WRITE8(f, p.stat)
			WRITEGHOST(f, withghosts and p.ghost or "")
		end
	end
	if not next(records) then
		f = {}
	end
	return string.format("%s/%s.sav2", cv_directory.string, G_BuildMapName(mapnum)), table.concat(f)
end
rawset(_G, "lb_write_map_store", function(map)
	write_segmented(writeMapStore(map, LiveStore[map], true))
end)

local function writeColdStore(store)
	local f = { "COLDSTORE" }
	WRITESTR(f, cv_directory.string)
	for map, records in pairs(store) do
		WRITENUM(f, map)
		WRITE16(f, tonumber(mapChecksum(map) or "0", 16))
		WRITENUM(f, #records)
		for _, record in ipairs(records) do
			WRITENUM(f, record.id)
			WRITENUM(f, record.flags)
			WRITENUM(f, record.time)
			WRITE8(f, #record.splits)
			for _, v in ipairs(record.splits) do
				WRITENUM(f, v)
			end
			WRITE8(f, #record.players)
			for _, p in ipairs(record.players) do
				WRITESTR(f, p.name)
				WRITESTR(f, p.skin)
				WRITE8(f, p.color)
				WRITE8(f, p.stat)
				WRITEGHOST(f, "")
			end
		end
	end
	return table.concat(f)
end

local function writeIndex()
	local f = {}
	WRITE8(f, INDEX_VERSION)
	WRITENUM(f, NextID)
	for v in pairs(Dirty) do
		WRITENUM(f, v)
	end
	local out = io.open(string.format("%s/%s.sav2", cv_directory.string, "index"), "wb")
	out:write(table.concat(f))
	out:close()
end

local function loadIndex()
	local f = io.open(string.format("%s/%s.sav2", cv_directory.string, "index"), "rb")
	if READ8(f) > INDEX_VERSION then
		error("Failed to load index (too new)", 2)
	end
	NextID = READNUM(f)
	Dirty = {}
	print("Loading index")
	while f:read(0) do
		Dirty[READNUM(f)] = true
	end
	f:close()
end

local function dumpStoreToFile(lbname, store)
	for mapid, records in pairs(store) do
		write_segmented(writeMapStore(mapid, records, true))
	end
	writeIndex()
end

local function recordsIdentical(a, b)
	if a.id ~= b.id or a.map ~= b.map or a.flags ~= b.flags or a.time ~= b.time or #a.players ~= #b.players then return false end
	for i, s in ipairs(a.splits) do
		if s ~= b.splits[i] then return false end
	end
	for i, p in ipairs(a.players) do
		local bp = b.players[i]
		if p.name ~= bp.name or p.skin ~= bp.skin or p.color ~= bp.color or p.stat ~= bp.stat then return false end
	end
	return true
end

local function mergeStore(other, iscold, deletelist)
	-- first, get the IDs of all records in here
	local my_mapforid = {}
	for map, records in pairs(LiveStore) do
		for i, record in ipairs(records) do
			my_mapforid[record.id] = { map = map, rec = record, i = i }
		end
	end

	local other_mapforid = {}
	for map, records in pairs(other) do
		for i, record in ipairs(records) do
			other_mapforid[record.id] = { map = map, rec = record, i = i }
		end
	end

	-- check the ids of the other store's records to see if anything moved
	for id in pairs(other_mapforid) do
		if my_mapforid[id] and my_mapforid[id].map ~= other_mapforid[id].map then
			-- move
			LiveStore[other_mapforid[id].map] = $ or {}
			table.insert(LiveStore[other_mapforid[id].map], other_mapforid[id].rec)
			LiveStore[my_mapforid[id].map][my_mapforid[id].i] = false
			print(string.format("move %d %d", other_mapforid[id].map, id))
		elseif my_mapforid[id] then
			if iscold or recordsIdentical(my_mapforid[id].rec, other_mapforid[id].rec) then
				-- passthrough
				print(string.format("passthrough %d %d", my_mapforid[id].map, id))
			else
				-- overwrite (this wipes the ghost, other rec has empty ghost)
				LiveStore[my_mapforid[id].map][my_mapforid[id].i] = other_mapforid[id].rec
				print(string.format("overwrite %d %d", my_mapforid[id].map, id))
			end
		elseif not Dirty[id] then
			-- add
			LiveStore[other_mapforid[id].map] = $ or {}
			table.insert(LiveStore[other_mapforid[id].map], other_mapforid[id].rec)
			print(string.format("add %d %d", other_mapforid[id].map, id))
		else
			-- if it's not in livestore and is in coldstore, but it's marked dirty, then it's a deleted cold record
			print(string.format("ignoring %d %d", other_mapforid[id].map, id))
		end
	end

	-- check for records that exist in our store but not the other, and delete them
	-- (unless they're dirty. don't wipe new records when the server shuts down)
	for id in pairs(my_mapforid) do
		if (iscold and not (other_mapforid[id] or Dirty[id])) or (deletelist and deletelist[id]) then
			-- delete
			LiveStore[my_mapforid[id].map][my_mapforid[id].i] = false
			print(string.format("delete %d %d", my_mapforid[id].map, id))
			if not other_mapforid[id] then
				print("not in other")
			end
			if not Dirty[id] then
				print("not dirty")
			end
			if deletelist and deletelist[id] then
				print("deletelist")
			end
		end
	end

	-- now delete the gaps (dear god...)
	for map, records in pairs(LiveStore) do
		for i = #records, 1, -1 do
			if records[i] == false then
				table.remove(records, i)
			end
		end
	end

	-- hopefully this gets rewritten soon
end

-- GLOBAL
-- Returns a list of all maps with records
local function MapList()
	local maplist = {}
	for mapid, records in pairs(LiveStore) do
		if next(records) then
			table.insert(maplist, mapid)
		end
	end
	table.sort(maplist)

	return maplist
end
rawset(_G, "lb_map_list", MapList)

-- Insert mode separated records from the flat sourceTable into dest
local function insertRecords(dest, sourceTable, modeSep)
	if not sourceTable then return end

	local mode = nil
	for _, record in ipairs(sourceTable) do
		mode = record.flags & modeSep
		dest[mode] = $ or {}
		table.insert(dest[mode], record)
	end
end

-- GLOBAL
-- Construct the leaderboard table of the supplied mapid
-- combines the ColdStore and LiveStore records
local function GetMapRecords(map, modeSep)
	local mapRecords = {}

	-- Insert LiveStore records
	insertRecords(mapRecords, LiveStore[map], modeSep)

	-- Sort records
	for _, records in pairs(mapRecords) do
		table.sort(records, lbComp)
	end

	-- Remove duplicate entries
	for _, records in pairs(mapRecords) do
		local seen = {}
		local i = 1
		while i <= #records do
			local namestr = ""
			for _, p in ipairs(records[i].players) do
				namestr = $..p.name.."\x00" -- need a separator to avoid wacky stuff
			end
			if seen[namestr] then
				table.remove(records, i)
			else
				seen[namestr] = true
				i = i + 1
			end
		end
	end

	return mapRecords
end
rawset(_G, "lb_get_map_records", GetMapRecords)

-- GLOBAL
-- Save a record to the LiveStore and write to disk
-- SaveRecord will replace the record holders previous record
local function SaveRecord(score, map, modeSep)
	LiveStore[map] = $ or {}
	local inserted = insertOrReplace(LiveStore[map], score, modeSep)
	if inserted then
		score.id = NextID
		NextID = $ + 1
	end
	Dirty[score.id] = true

	print("Saving score"..(inserted and " ("..score.id..")" or ""))
	if isserver then
		write_segmented(writeMapStore(map, LiveStore[map], true))
		writeIndex()
	end
end
rawset(_G, "lb_save_record", SaveRecord)

local function oldParseScore(str)
	-- Leaderboard is stored in the following tab separated format
	-- mapnum, name, skin, color, time, splits, flags, stat
	local t = {}
	for word in (str.."\t"):gmatch("(.-)\t") do
		table.insert(t, word)
	end

	local splits = {}
	if t[6] != nil then
		for str in t[6]:gmatch("([^ ]+)") do
			table.insert(splits, tonumber(str))
		end
	end

	local flags = 0
	if t[7] != nil then
		flags = tonumber(t[7])
	end

	local stats = nil
	if t[8] != nil then
		if #t[8] >= 2 then
			local speed = tonumber(string.sub(t[8], 1, 1))
			local weight = tonumber(string.sub(t[8], 2, 2))
			stats = stat_t(speed, weight)
		end
	end

	--local checksum = t[9] or ""

	return score_t(
		tonumber(t[1]), -- Map
		flags,
		tonumber(t[5]),	-- Time
		splits,
		{
			player_t(
				t[2], -- Name
				t[3], -- Skin
				tonumber(t[4]), -- Color
				stats,
				string.rep("balls", 10000)
			)
		}
	)
end
rawset(_G, "lb_parse_score", oldParseScore)

local function convertToBinary(f)
	print("Converting "..LEADERBOARD_FILE_OLD.." to binary")
	local output = {}
	local store = {}
	NextID = 1
	for l in f:lines() do
		local score = oldParseScore(l)
		score.id = NextID
		store[score.map] = $ or {}
		table.insert(store[score.map], score)
		NextID = $ + 1
	end
	Dirty = {}
	dumpStoreToFile(LEADERBOARD_FILE, store)
end

local function parseScoreBinary(f, map)
	local id = READNUM(f)
	local flags = READNUM(f)
	local time = READNUM(f)

	local splits = {}
	local numsplits = READ8(f)
	for i = 1, numsplits do
		table.insert(splits, READNUM(f))
	end

	local players = {}
	local numplayers = READ8(f)
	for i = 1, numplayers do
		local name = READSTR(f)
		local skin = READSTR(f)
		local color = READ8(f)
		local stats = READ8(f)
		local ghost = READGHOST(f)
		table.insert(players, player_t(name, skin, color, stat_t(stats >> 4, stats & 0xf), ghost))
	end

	return score_t(
		map,
		flags,
		time,
		splits,
		players,
		id
	)
end

local function loadStore(f, filename, map)
	local store = {}

	if f:read(11) ~= "LEADERBOARD" then
		error(string.format("Failed to read %s: bad magic", filename), 2)
	end
	local version = READ8(f)
	if version > LEADERBOARD_VERSION then
		error(string.format("Failed to read %s: version %d not supported (highest is %d)", filename, version, LEADERBOARD_VERSION), 2)
	end

	local checksum = READ16(f)
	local numrecords = READNUM(f)
	for i = 1, numrecords do
		local score = parseScoreBinary(f, map)
		if score then
			table.insert(store, score)
		end
	end

	f:close()

	return store
end

local function loadColdStore(f)
	local store = {}

	if f:read(9) ~= "COLDSTORE" then
		error("Failed to read cold store: bad magic", 2)
	end
	local servername = READSTR(f)

	while f:read(0) do
		local mapnum = READNUM(f)
		local checksum = READ16(f)
		local numrecords = READNUM(f)
		for i = 1, numrecords do
			local score = parseScoreBinary(f, mapnum)
			if score then
				store[mapnum] = $ or {}
				table.insert(store[mapnum], score)
			end
		end
	end

	f:close()

	return store
end

-- Read and parse a store file
local function loadStoreFile()
	local store = {}
	for i = 1, #mapheaderinfo do
		local filename = string.format("%s/%s.sav2", cv_directory.string, G_BuildMapName(i))
		local f = read_segmented(filename)
		if f then
			store[i] = loadStore(f, filename, i)
		end
	end
	loadIndex()
	return store
end

local function AddColdStoreBinary(str)
	loadIndex()
	local f = FakeReader(lb_base128_decode(str))
	local store = loadColdStore(f)
	mergeStore(store, true)
end
rawset(_G, "lb_add_coldstore_binary", AddColdStoreBinary)

-- GLOBAL
-- Command for moving records from one map to another
local function moveRecords(from, to, modeSep)
	local function moveRecordsInStore(store)
		if not store[from.id] then
			return 0
		end

		store[to.id] = $ or {}
		for i, score in ipairs(store[from.id]) do
			score.map = to.id
			insertOrReplace(store[to.id], score, modeSep)
		end

		-- Destroy the original table
		store[from.id] = nil
	end

	-- move livestore records and write to disk
	moveRecordsInStore(LiveStore)

	if isserver then
		dumpStoreToFile(LEADERBOARD_FILE, LiveStore)

		-- move coldstore records
		local ok, coldstore = pcall(loadStoreFile, COLDSTORE_FILE)
		if ok and coldstore then
			moveRecordsInStore(coldstore)
			dumpStoreToFile(COLDSTORE_FILE, coldstore)
		end
	end
end
rawset(_G, "lb_move_records", moveRecords)

local netreceived, netdeleted
local function netvars(net)
	NextID = net($)
	if isserver then
		print("sending")
		local send = {}
		local highest = 0
		local byid = {}
		for map, records in pairs(LiveStore) do
			send[map] = {}
			for _, record in ipairs(records) do
				if Dirty[record.id] then
					table.insert(send[map], record)
					print(record.id)
				end
				byid[record.id] = record
				highest = max($, record.id)
			end
		end
		-- need this in case the very latest records are deleted
		for i in pairs(Dirty) do
			highest = max($, i)
		end
		local deleted = {}
		for i = 1, highest do
			if not byid[i] then
				deleted[i] = true
			end
		end
		local dat = writeColdStore(send)
		net(dat, deleted)
	else
		netreceived, netdeleted = net("gotta wait until PlayerJoin because UnArchiveTables hasn't been run yet", "deletions yay")
	end
end
addHook("NetVars", netvars)

addHook("PlayerJoin", function(p)
	if netreceived and #consoleplayer == p then
		local newstore = loadColdStore(FakeReader(netreceived))
		mergeStore(newstore, false, netdeleted)
		dumpStoreToFile(LEADERBOARD_FILE, LiveStore)
	end
	netreceived = nil
	netdeleted = nil
end)

COM_AddCommand("lb_write_coldstore", function(player, filename)
	if not filename then
		CONS_Printf(player, "Usage: lb_write_coldstore <filename>")
		return
	end

	if filename:sub(#filename-3) != ".txt" then
		filename = $..".txt"
	end

	local store = {}
	for map, records in pairs(LiveStore) do
		store[map] = $ or {}
		for _, record in ipairs(records) do
			insertOrReplace(store[map], record, -1)
		end
	end

	local dat = writeColdStore(store)
	local f = io.open(COLDSTORE_FILE, "wb")
	f:write(dat)
	f:close()

	-- B-B-BUT WHAT ABOUT PLAYER NAMES?
	-- right now we use base128 encoding, which doesn't have ] in its character set so that's not an issue
	-- if base252 ever becomes real we'll have to make it base251 and exclude ]
	write_segmented(filename, "lb_add_coldstore_binary[["..lb_base128_encode(dat).."]]")

	print("Cold store script written to "..filename.." (rename to "..filename:gsub(".txt", ".lua").."!)")
	Dirty = {}
	writeIndex()
end, COM_LOCAL)

COM_AddCommand("lb_list_records", function(player, map)
	local mapnum = gamemap
	if map then
		mapnum = mapnumFromExtended(map)
		if not mapnum then
			print(string.format("invalid map '%s'", map))
			return
		end
	end

	if not LiveStore[mapnum] then
		print(string.format("%s has no records", G_BuildMapName(mapnum)))
		return
	end

	print(string.format("Records for %s:", G_BuildMapName(mapnum)))
	for _, record in ipairs(LiveStore[mapnum]) do
		local namestr = ""
		for _, p in ipairs(record.players) do
			namestr = $..string.format("%s%s ", SG_Color2Chat and SG_Color2Chat[p.color] or "", p.name)
		end
		print(string.format("%7d %s %s", record.id, ticsToTime(record.time, true), namestr))
	end
end, COM_LOCAL)

COM_AddCommand("lb_download_live_records", function(player, filename)
	if not filename then
		CONS_Printf(player, "Usage: lb_download_live_records <filename>")
		return
	end

	if filename:sub(#filename-4) != ".sav2" then
		filename = $..".sav2"
	end
	dumpStoreToFile(filename, LiveStore)
end, COM_LOCAL)

COM_AddCommand("lb_convert_to_binary", function()
	local f = io.open(LEADERBOARD_FILE_OLD)
	convertToBinary(f)
	if f then f:close() end
end, COM_LOCAL)

COM_AddCommand("lb_wipe_records", function()
	local map = gamemap
	for i, record in ipairs(LiveStore[map]) do
		LiveStore[map][i] = nil
		Dirty[record.id] = true
	end
	dumpStoreToFile(LEADERBOARD_FILE, LiveStore)
end, COM_LOCAL)

-- very ugly test command
COM_AddCommand("lb_move", function()
	local test = LiveStore[1][1]
	LiveStore[1][1] = nil
	LiveStore[2] = { test }
	test.map = 2
	Dirty[test.id] = true
	write_segmented(writeMapStore(1, LiveStore[1], true))
	write_segmented(writeMapStore(2, LiveStore[2], true))
	writeIndex()
end, COM_LOCAL)

-- Load the livestore
LiveStore = loadStoreFile()
