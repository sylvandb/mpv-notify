#!/usr/bin/lua5.2

if not arg then
	return
end

local function usage()
	print("Usage: dl {outfile} {{artist} {album}} | {id}")
	print("Where id is either an mbid or either simple equation:")
	print("  asin={asin}\n  mbid={mbid}")
end

local function print_debug(x)
	print(x)
	return
end

local artist = ""
local album = ""
local mbid = ""
local artfile = arg[1]
if not artfile or artfile == "" then
	usage()
	return
end

if arg[3] then
	artist = arg[2]
	album = arg[3]
	mbid = arg[4] or ""
elseif arg[2] then
	if arg[2]:sub(1, 5) == "mbid=" then
		mbid = arg[2]:sub(6)
	elseif arg[2]:sub(1, 5) == "asin=" then
		asin = arg[2]:sub(6)
	else
		mbid = arg[2]
	end
	print(("mbid=%s\nasin=%s"):format(mbid, asin))
else
	usage()
	return
end


local http = require("socket.http")
http.TIMEOUT = 3

local mbca = require("mbcoverart")
mbca.print_debug = print_debug

local d = mbca.download_cover_art(artist, album, mbid)

if d then
	print(("Saving %d bytes of cover art to %s"):format(string.len(d), artfile))
	local f = io.open(artfile, "w+")
	f:write(d)
	f:flush()
	f:close()
end
