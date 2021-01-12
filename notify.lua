-- notify.lua -- Desktop notifications for mpv.
-- Just put this file into your ~/.mpv/lua folder and mpv will find it.
--
-- Copyright (c) 2021 Sylvan Butler
-- Copyright (c) 2014 Roland Hieber
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.



-------------------------------------------------------------------------------
-- helper functions
-------------------------------------------------------------------------------


function print_debug(s)
	--print("DEBUG: " .. s) -- comment/not to hide/show debug output
	return true
end


local err = ""
-- TODO: dirty hack, may only work on Linux.
function is_readable(fn)
	local f = nil
	f, err = io.open(fn, "r")
	if f then
		f:close()
		return true
	end
	return false
end


-- url-escape a string, per RFC 2396, Section 2
function string.urlescape(str)
	local s, c = string.gsub(str, "([^A-Za-z0-9_.!~*'()/-])",
		function(c)
			return ("%%%02x"):format(c:byte())
		end)
	return s;
end


-- escape string for html
function string.htmlescape(str)
	str = string.gsub(str, "<", "&lt;")
	str = string.gsub(str, ">", "&gt;")
	str = string.gsub(str, "&", "&amp;")
	str = string.gsub(str, "\"", "&quot;")
	str = string.gsub(str, "'", "&apos;")
	return str
end


-- escape string for shell inclusion
function string.shellescape(str)
	str = string.gsub(str, "[\r\n]", " ")
	str = string.gsub(str, " +$", "")
	str = string.gsub(str, "^ +", "")
	return "'"..string.gsub(str, "'", "'\"'\"'").."'"
end


-- converts string to a valid filename on most (modern) filesystems
function string.safe_filename(str)
	local s, _ = string.gsub(str, "([^A-Za-z0-9_.-])",
		function(c)
			return ("%02x"):format(c:byte())
		end)
	return s;
end



-------------------------------------------------------------------------------
-- here we go.
-------------------------------------------------------------------------------


local DOWNLOAD_COVER_ART = true


local http = nil
--local json = nil
if DOWNLOAD_COVER_ART then
	http = require("socket.http")
	http.TIMEOUT = 3
	http.USERAGENT = "mpv-notify/0.2 (github.com/sylvandb/mpv-notify)"
	--json = require "json" -- https://github.com/rxi/json.lua
end

local posix = require("posix")


local CACHE_DIR = os.getenv("XDG_CACHE_HOME")
CACHE_DIR = CACHE_DIR or os.getenv("HOME").."/.cache"
CACHE_DIR = CACHE_DIR.."/mpv/coverart"
print_debug("making " .. CACHE_DIR)
local SUBDIRS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
SUBDIRS:gsub(".", function(c)
	os.execute("mkdir -p -- " .. string.shellescape(CACHE_DIR) .. "/" .. c)
end)


-- size can be 250, 500 or 1200
-- https://wiki.musicbrainz.org/Cover_Art_Archive/API#Cover_Art_Archive_Metadata
local COVER_ART_SIZE = "1200"
-- scale can be the same or a different size
local COVER_ART_SCALE = "1200"
local NO_FETCH_PREFIX = "404_no-"
local AUTO_NO_FETCH = true

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
local COVER_ART = "http://coverartarchive.org/release/%s/front-" .. COVER_ART_SIZE
local AMAZON_ART = "http://images.amazon.com/images/P/%s.01._SCLZZZZZZZ_.jpg"


function tmpname()
	local _, fname = posix.mkstemp(CACHE_DIR .. "/rescale.XXXXXX")
	return fname
end


-- scale an image file
-- @return boolean of success
function scale_image(src, dst)
	local convert_cmd = ("convert -scale x%s -- %s %s"):format(
		COVER_ART_SCALE, string.shellescape(src), string.shellescape(dst))
	print_debug("executing " .. convert_cmd)
	return not not os.execute(convert_cmd)
end


function no_download_flag(artist, album)
	if NO_FETCH_PREFIX then
		-- TODO: check flag being too old???
		local flagname = cache_compute_filename(artist, album, NO_FETCH_PREFIX)
		if is_readable(flagname) then
			return true
		end
	end
	return false
end


function no_download_flag_set(artist, album, mbid, asin)
	if AUTO_NO_FETCH and NO_FETCH_PREFIX then
		local flagname = cache_compute_filename(artist, album, NO_FETCH_PREFIX)
		local f = io.open(flagname, "w+")
		if mbid then
			f:write(("mbid=%s\n"):format(mbid))
		end
		if asin then
			f:write(("asin=%s\n"):format(asin))
		end
		f:close()
	end
end


function cache_compute_filename(artist, album, prefix)
	local filename = artist .. "_" .. album
	local dirname = string.safe_filename(filename:gsub(" ", ""):gsub("^THE", ""):sub(1, 1):upper())
	return CACHE_DIR .. "/" .. dirname .. "/" .. (prefix or "") .. string.safe_filename(filename) .. ".png"
end


-- store cover art into cache
-- @return file name of cover art, or nil in case of error
function cache_set_cover_art(artist, album, artdata, artfile)
	local file_is_tmp = false
	if artdata then
		file_is_tmp = true
		artfile = tmpname()
		local f = io.open(artfile, "w+")
		f:write(artdata)
		f:flush()
		f:close()
	end

	if not artist or artist == "" or not album or album == "" then
		-- cannot cache
		return artfile
	end

	local cache_filename = cache_compute_filename(artist, album)

	-- make it a nice size
	if COVER_ART_SIZE ~= COVER_ART_SCALE or not file_is_tmp then
		if scale_image(artfile, cache_filename) then
			if file_is_tmp then
				if not os.remove(artfile) then
					print("could not remove" .. artfile .. ", please remove it manually")
				end
			end
			return cache_filename
		end
		print(("could not scale %s to %s"):format(artfile, cache_filename))
	end

	if file_is_tmp then
		if os.rename(artfile, cache_filename) then
			return cache_filename
		end
		print(("could not rename %s to %s"):format(artfile, cache_filename))
	end

	return artfile
end


-- get cover art from cache
-- @return file name of cover art, or nil in case of error
function cache_get_cover_art(artist, album)
	print_debug("cache_get_cover_art parameters:")
	print_debug("artist: " .. artist)
	print_debug("album: " .. album)

	if not artist or artist == "" or not album or album == "" then
		print("cache requires artist and album for cover art.")
		return nil
	end

	local cache_filename = cache_compute_filename(artist, album)
	if is_readable(cache_filename) then
		print_debug("cache found cover art: " .. cache_filename)
		return cache_filename  -- exists and is readable
	elseif string.find(err, "[Pp]ermission denied") then
		print(("cannot read from cached file %s: %s"):format(cache_filename, err))
		return nil
	end
	-- no cached art
	return nil
end


function folder_get_cover_art(artist, album)
	-- first try finding local cover art
	local pathname = mp.get_property_native("path")
	-- pathname = os.getenv("PWD") .. "/" .. pathname
	print_debug("path: " .. pathname)
	pathname = find_folder_cover_art(pathname)
	if pathname and pathname ~= "" then
		print_debug("folder found cover art: " .. pathname)
		return cache_set_cover_art(artist, album, nil, pathname)
	end
	return nil
end


-- look for a list of possible cover art images in the same folder as the file
-- @param absolute filename name of currently played file, or nil if no match
function find_folder_cover_art(filename)
	if not filename or string.len(filename) < 1 then
		return nil
	end

	print_debug("find_folder_cover_art: filename is " .. filename)

	local cover_extensions = { "png", "jpg", "jpeg", "gif" }
	local cover_names = { "cover", "front", "AlbumArtwork", "folder", "back", "insert" }

	local path = string.match(filename, "^(.*/)[^/]+$")

	for _,name in pairs(cover_names) do
		for _,ext in pairs(cover_extensions) do
			morenames = { name, string.upper(name),
				string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2, -1) }
			moreexts = { ext, string.upper(ext) }
			for _,name in pairs(morenames) do
				for _,ext in pairs(moreexts) do
					local fn = path .. name .. "." .. ext
					--print_debug("find_folder_cover_art: trying " .. fn)
					if is_readable(fn) then
						print_debug("find_folder_cover_art: match at " .. fn)
						return fn
					end
				end
			end
		end
	end
	return nil
end


-- lookup MBID from MusicBrainz, needed for Cover Art Archive
function lookup_musicbrainz_id(artist, album, mbid)
	local valid_mbid = function(s)
		return s and string.len(s) > 0 and not string.find(s, "[^0-9a-fA-F-]")
	end

	-- TODO: how to lookup asin given mbin?
	if mbid and valid_mbid(mbid) then
		return mbid, lookup_musicbrainz_release_asin(mbid)
	end

	local asin = nil
	local query = ('artist:"%s" AND release:"%s"'):format(artist:gsub('"', ""), album:gsub('"', ""))
	local url = MBID_QUERY .. string.urlescape(query)
	print("lookup album MBID with: " .. url)
	local d, c, h = http.request(url)
	-- poor man's XML parsing:
	mbid = string.match(d or "",
		"<%s*release%s+[^>]*id%s*=%s*['\"]%s*([0-9a-fA-F-]+)%s*['\"]")
	asin = string.match(d or "", "%s*<asin>(%w+)</asin>")
	if not mbid or not valid_mbid(mbid) then
		print("MusicBrainz returned no match.")
		print_debug("content: " .. d)
		return nil
	end
	if not asin then
		print("MusicBrainz missing ASIN")
		print_debug("content: " .. d)
	end
	return mbid, asin
end


-- lookup ASIN from MusicBrainz given MBID, needed for Amazon cover art
function lookup_musicbrainz_release_asin(mbid)
	local url = MBID_LOOKUP .. mbid
	print("lookup album MBID with: " .. url)
	local d, c, h = http.request(url)
	-- poor man's XML parsing:
	asin = string.match(d or "", "%s*<asin>(%w+)</asin>")
	if not asin then
		print("MusicBrainz missing ASIN")
		print_debug("content: " .. d)
	end
	return asin
end


-- fetch image from amazon cover art, requires ASIN
function download_amazon_cover_art(art_id)
	local url = (AMAZON_ART):format(art_id)
	print("downloading album cover from: " .. url)
	local d, c, h = http.request(url)
	if c ~= 200 then
		print(("Amazon Art returned HTTP %s for MBID: %s"):format(c, art_id))
		return nil
	end
	if not d or string.len(d) < 1 then
		print(("Amazon Art returned no content for MBID: %s"):format(art_id))
		print_debug("HTTP response: " .. d)
		return nil
	end
	return d
end


-- fetch image from Cover Art Archive, requires MBID
function download_archive_cover_art(art_id)
	local url = (COVER_ART):format(art_id)
	print("downloading album cover from: " .. url)
	local d, c, h = http.request(url)
	if c ~= 200 then
		print(("Cover Art Archive returned HTTP %s for MBID: %s"):format(c, art_id))
		return nil
	end
	if not d or string.len(d) < 1 then
		print(("Cover Art Archive returned no content for MBID: %s"):format(art_id))
		print_debug("HTTP response: " .. d)
		return nil
	end
	return d
end


-- fetch cover art from MusicBrainz/Cover Art Archive
-- @return file name of downloaded cover art, or nil in case of error
-- @param mbid optional MusicBrainz release ID
function download_cover_art(artist, album, mbid)
	if not DOWNLOAD_COVER_ART then
		return nil
	end
	if no_download_flag(artist, album) then
		print("not downloading album art")
		return nil
	end
	print_debug("download_cover_art parameters:")
	print_debug("artist: " .. artist)
	print_debug("album: " .. album)
	print_debug("mbid: " .. mbid)

	print_debug("downloading album art")

	local asin = nil
	local d = nil

	mbid, asin = lookup_musicbrainz_id(artist, album, mbid)
	if not mbid then
		no_download_flag_set(artist, album)
		return nil
	end
	print_debug("using MusicBrainz ID / ASIN: " .. mbid .. " / " .. (asin or "nil"))

	d = download_archive_cover_art(mbid)
	if not d and asin then
		d = download_amazon_cover_art(asin)
	end
	if not d then
		no_download_flag_set(artist, album, mbid, asin)
		return nil
	end

	print_debug(("downloaded %d bytes cover art for MBID: %s"):format(string.len(d), mbid))
	return cache_set_cover_art(artist, album, d)
end


function get_cover_art(artist, album, album_mbid)
	-- best place for art is the cache
	local art_file = cache_get_cover_art(artist, album)

	-- or perhaps in the original folder
	if not art_file then
		art_file = folder_get_cover_art(artist, album)
	end

	-- finally check the cover art archive online
	if not art_file
	   and ((artist ~= "" and album ~= "") or album_mbid ~= "") then
		art_file = download_cover_art(artist, album, album_mbid)
	end

	return art_file
end


function notify_current_track()
	if mp.get_property_native("pause") then
		return
	end

	local data = mp.get_property_native("metadata")
	if not data then
		return
	end

	function get_metadata(data, keys)
		for _,v in pairs(keys) do
			if data[v] and string.len(data[v]) > 0 then
				return data[v]
			end
		end
		return ""
	end
	-- srsly MPV, why do we have to do this? :-(
	local artist = get_metadata(data, {"artist", "ARTIST"})
	local album = get_metadata(data, {"album", "ALBUM"})
	local album_mbid = get_metadata(data, {"MusicBrainz Album Id",
		"MUSICBRAINZ_ALBUMID"})
	local title = get_metadata(data, {"title", "TITLE", "icy-title"})

	print_debug("notify_current_track: relevant metadata:")
	print_debug("artist: " .. artist)
	print_debug("album: " .. album)
	print_debug("album_mbid: " .. album_mbid)

	local summary = ""
	local body = ""
	local params = ""
	local scaled_image = get_cover_art(artist, album, album_mbid)

	if scaled_image and string.len(scaled_image) > 1  then
		print_debug("found cover art in: " .. scaled_image)
		params = " -i " .. string.shellescape(scaled_image)
	else
		print("no cover art")
		params = " -i mpv"
	end

	if artist == "" then
		summary = string.shellescape("Now playing:")
	else
		summary = string.shellescape(string.htmlescape(artist))
	end
	if title == "" then
		body = string.shellescape(mp.get_property_native("filename"))
	else
		if album == "" then
			body = string.shellescape(string.htmlescape(title))
		else
			-- <br /> doesn't break (literal) nor does \n even embedded literal, but \r does
			body = string.shellescape(("%s\\rfrom <i>%s</i>"):format(
				string.htmlescape(title), string.htmlescape(album)))
		end
	end

	local command = ("notify-send -a mpv %s -- %s %s"):format(params, summary, body)
	print("sending command: " .. command)
	os.execute(command)
end



-- notify when media file is loaded
mp.register_event("file-loaded", notify_current_track)

-- notify when metadata is loaded - will double notify every new file
--mp.observe_property("metadata", nil, function(name, value) notify_current_track(); end)

-- notify when paused/unpaused - will double notify every new file
--mp.observe_property("pause", nil, function(name, value) notify_current_track(); end)

-- notify when unpaused
mp.observe_property("pause", "bool", function(name, value)
	--print(("%s: %s"):format(name, value))
	if not value then
		notify_current_track()
	end
end)
