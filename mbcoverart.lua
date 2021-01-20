local _M = {}
if module then -- heuristic for exporting a global package table
	mbcoverart = _M
end


local http = require("socket.http")
http.TIMEOUT = 3
http.USERAGENT = "mpv-notify/0.2 (github.com/sylvandb/mpv-notify)"
--json = require "json" -- https://github.com/rxi/json.lua


-- size can be 250, 500 or 1200
-- https://wiki.musicbrainz.org/Cover_Art_Archive/API#Cover_Art_Archive_Metadata
_M.COVER_ART_SIZE = "1200"

-- musicbrainz api
local MBID_BASE = "http://musicbrainz.org/ws/2/release"
-- https://musicbrainz.org/doc/MusicBrainz_API
-- could use fmt=json
-- but it doesn't seem to return the same results, e.g. limit and asin, maybe use before limit?
-- to lookup, append the MBID
local MBID_LOOKUP = MBID_BASE .. "/"
-- to get the MBID, append query
local MBID_QUERY = MBID_BASE .. "?limit=1&query="

-- coverart url, format in the MBID
local COVER_ART = "http://coverartarchive.org/release/%s/front-" .. _M.COVER_ART_SIZE
local AMAZON_ART = "http://images.amazon.com/images/P/%s.01._SCLZZZZZZZ_.jpg"



local function print_debug(s)
	--_M.print("DEBUG mbcoverart: " .. s) -- comment/not to hide/show debug output
	return true
end
_M.print_debug = print_debug
_M.print = print


-- url-escape a string, per RFC 2396, Section 2
local function urlescape(str)
	local s, c = string.gsub(str, "([^A-Za-z0-9_.!~*'()/-])",
		function(c)
			return ("%%%02x"):format(c:byte())
		end)
	return s;
end



local function valid_mbid(s)
	return s and string.len(s) > 0 and not string.find(s, "[^0-9a-fA-F-]")
end

local function valid_asin(s)
	return s and string.len(s) > 0 and not string.find(s, "[^0-9A-Z]")
end


-- lookup ASIN from MusicBrainz given MBID, needed for Amazon cover art
local function lookup_musicbrainz_release_asin(mbid)
	local url = MBID_LOOKUP .. mbid
	_M.print_debug("lookup album ASIN with: " .. url)
	local d, c, h = http.request(url)
	-- poor man's XML parsing:
	asin = string.match(d or "", "%s*<asin>(%w+)</asin>")
	if not asin or not valid_asin(asin) then
		_M.print("MusicBrainz failed ASIN lookup")
		_M.print_debug("content: " .. d)
	end
	return asin
end
_M.lookup_musicbrainz_release_asin = lookup_musicbrainz_release_asin


-- lookup MBID from MusicBrainz, needed for Cover Art Archive
local last_id_query = nil
local last_id_result = nil
local function lookup_musicbrainz_id(artist, album, mbid)
	if mbid and valid_mbid(mbid) then
		local last_mbid, last_asin = last_id_result
		if last_mbid == mbid then
			return last_id_result
		end
		last_id_query = mbid
		last_id_result = mbid, lookup_musicbrainz_release_asin(mbid)
		return last_id_result
	end

	if not (artist and artist ~= "" and album and album ~= "") then
		_M.print("MBID lookup requires artist and album")
		return nil
	end

	local asin, d = nil, nil
	local query = ('artist:"%s" AND release:"%s"'):format(artist:gsub('"', ""), album:gsub('"', ""))
	if last_id_query == query then
		return last_id_result
	else
		local url, c, h = MBID_QUERY .. urlescape(query)
		_M.print_debug("lookup album MBID with: " .. url)
		d, c, h = http.request(url)
		-- poor man's XML parsing:
		mbid = string.match(d or "",
			"<%s*release%s+[^>]*id%s*=%s*['\"]%s*([0-9a-fA-F-]+)%s*['\"]")
		asin = string.match(d or "", "%s*<asin>(%w+)</asin>")
		last_id_query = query
		last_id_result = mbid, asin
	end
	if not mbid or not valid_mbid(mbid) then
		_M.print("MusicBrainz returned no match.")
		_M.print_debug("content: " .. d)
		return nil
	end
	if not asin then
		_M.print("MusicBrainz missing ASIN")
		_M.print_debug("content: " .. d)
	end
	return last_id_result
end
_M.lookup_musicbrainz_id = lookup_musicbrainz_id


-- fetch image from amazon cover art, requires ASIN
local function download_amazon_cover_art(art_id)
	local url = (AMAZON_ART):format(art_id)
	if not valid_asin(art_id) then
		_M.print("Bogus ASIN: " .. art_id)
		return nil
	end
	_M.print("downloading album cover from: " .. url)
	local d, c, h = http.request(url)
	if c ~= 200 then
		_M.print(("Amazon Art returned HTTP %s for MBID: %s"):format(c, art_id))
		return nil
	end
	if not d or string.len(d) < 1 then
		_M.print(("Amazon Art returned no content for MBID: %s"):format(art_id))
		_M.print_debug("HTTP response: " .. d)
		return nil
	end
	return d
end
_M.download_amazon_cover_art = download_amazon_cover_art


-- fetch image from Cover Art Archive, requires MBID
local function download_archive_cover_art(art_id)
	local url = (COVER_ART):format(art_id)
	if not valid_mbid(art_id) then
		_M.print("Bogus MBID: " .. art_id)
		return nil
	end
	_M.print("downloading album cover from: " .. url)
	local d, c, h = http.request(url)
	if c ~= 200 then
		_M.print(("Cover Art Archive returned HTTP %s for MBID: %s"):format(c, art_id))
		return nil
	end
	if not d or string.len(d) < 1 then
		_M.print(("Cover Art Archive returned no content for MBID: %s"):format(art_id))
		_M.print_debug("HTTP response: " .. d)
		return nil
	end
	return d
end
_M.download_archive_cover_art = download_archive_cover_art


-- fetch cover art from MusicBrainz/Cover Art Archive
-- @return file name of downloaded cover art, or nil in case of error
-- @param mbid optional MusicBrainz release ID
local function download_cover_art(artist, album, mbid, asin)
	_M.print_debug("download_cover_art parameters:")
	_M.print_debug("artist: " .. artist)
	_M.print_debug("album: " .. album)
	_M.print_debug("mbid: " .. (mbid or ""))
	_M.print_debug("asin: " .. (asin or ""))

	local d = nil

	if not mbid or not asin then
		mbid, asin = lookup_musicbrainz_id(artist, album, mbid)
	end

	if not mbid then
		return nil
	end
	_M.print_debug("using MusicBrainz ID / ASIN: " .. mbid .. " / " .. (asin or "nil"))

	d = download_archive_cover_art(mbid)
	if not d and asin then
		d = download_amazon_cover_art(asin)
	end
	return d
end
_M.download_cover_art = download_cover_art



return _M
