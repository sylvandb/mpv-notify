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


-- TODO: dirty hack, may only work on Linux.
function read_error(fn)
	local f = nil
	local err = nil
	f, err = io.open(fn, "r")
	if f then
		f:close()
		return nil
	end
	return err
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
			return ("+%02x"):format(c:byte())
		end)
	return s;
end
-- legacy - deprecated version is not reversible
-- find . -type f | sort | grep '[^0-9+][1-9][0-9][^0-9]'; echo "========"; find . -type f | sort | grep '+'
function string.safe_filename0(str)
	local s, _ = string.gsub(str, "([^A-Za-z0-9_.-])",
		function(c)
			return ("%02x"):format(c:byte())
		end)
	return s;
end



-------------------------------------------------------------------------------
-- here we go.
-------------------------------------------------------------------------------


local COVER_ART_SIZE = "1200"
local DOWNLOAD_COVER_ART = true
local mbcoverart = nil
--local json = nil
if DOWNLOAD_COVER_ART then
	mbcoverart = require("mbcoverart")
	COVER_ART_SIZE = mbcoverart.COVER_ART_SIZE
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


-- scale can be the same as COVER_ART_SIZE or a different size
local COVER_ART_SCALE = COVER_ART_SIZE
local NO_FETCH_PREFIX = "404_no-"
local AUTO_NO_FETCH = true


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
		if not read_error(flagname) then
			return true
		end
	end
	return false
end


function no_download_flag_clear(artist, album)
	if AUTO_NO_FETCH and NO_FETCH_PREFIX then
		local flagname = cache_compute_filename(artist, album, NO_FETCH_PREFIX)
		os.remove(flagname)
	end
end

function no_download_flag_set(artist, album, mbid, asin)
	if AUTO_NO_FETCH and NO_FETCH_PREFIX then
		local flagname = cache_compute_filename(artist, album, NO_FETCH_PREFIX)
		local f = io.open(flagname, "w+")
		if f then
			if mbid and mbid ~= "" then
				f:write(("mbid=%s\n"):format(mbid))
			end
			if asin and asin ~= "" then
				f:write(("asin=%s\n"):format(asin))
			end
			f:close()
		end
	end
end


function cache_compute_filename(artist, album, prefix)
	local filename = string.gsub(artist .. "_" .. album, "[ \r\n.]", "")
	if filename:sub(1, 3):upper() == "THE" then
		filename = filename:sub(4)
	end
	local dirname = filename:sub(1, 1):upper()
	local pathname = CACHE_DIR .. "/" .. dirname:safe_filename() .. "/" .. (prefix or "") .. filename:safe_filename() .. ".png"
	-- legacy - rename old file to new name
	local name0 = CACHE_DIR .. "/" .. dirname:safe_filename0() .. "/" .. (prefix or "") .. filename:safe_filename0() .. ".png"
	if name0 ~= pathname then
		print("cache_rename " .. name0 .. " " .. pathname)
		os.rename(name0, pathname)
	end
	--print("cache: " .. pathname); print("kill it" .. nil)
	return pathname
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

	no_download_flag_clear(artist, album)
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
		print_debug("cache requires artist and album for cover art.")
		return nil
	end

	local cache_filename = cache_compute_filename(artist, album)
	local err = read_error(cache_filename)
	if not err then
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
	print_debug("folder get cover art for path: " .. pathname)
	pathname = find_folder_cover_art(pathname)
	if pathname and pathname ~= "" and not read_error(pathname) then
		print_debug("folder found cover art: " .. pathname)
		return cache_set_cover_art(artist, album, nil, pathname)
	end
	return nil
end


function ls_folder_files(folder, ending)
	local fnames, i = {}, 0
	local nameending = ""
	if ending then
		nameending = ' -iname "*.' .. ending .. '"'
	end
	local p = io.popen('find "' .. folder .. '" -maxdepth 1' .. nameending)
	-- -print0')
	for fname in p:lines() do
		i = i + 1
		fnames[i] = fname
	end
	p:close()
	return fnames
end


-- look for a list of possible cover art images in the same folder as the file
-- @param absolute filename name of currently played file, or nil if no match
function find_folder_cover_art(filename)
	if not filename or string.len(filename) < 1 then
		return nil
	end

	local path = string.match(filename, "^(.*/)[^/]+$")
	if not path or path == "" then
		path = "./"
	end
	print_debug("find_folder_cover_art: path: " .. path)

	local cover_extensions = { "png", "jpg", "jpeg", "gif" }
	local cover_name_parts = { "cover", "front", "art", "folder", "back", "insert" }

	for _, ext in ipairs(cover_extensions) do
		for _, fname in ipairs(ls_folder_files(path, ext)) do
			for _, part in ipairs(cover_name_parts) do
				if fname:lower():find(part) then
					print(("find_folder_cover_art: match part '%s' in: %s"):format(part, fname))
					return fname
				end
			end
		end
	end
	return nil
end


function download_cover_art_to_cache(artist, album, mbid)
	artist = artist or ""
	album = album or ""
	mbid = mbid or ""
	if not ((artist ~= "" and album ~= "") or mbid ~= "") then
		return nil
	end

	if not mbcoverart or no_download_flag(artist, album) then
		print("not downloading album art")
		return nil
	end

	mbid, asin = mbcoverart.lookup_musicbrainz_id(artist, album, mbid)
	print_debug(("downloading album art: (%s) (%s) (%s) (%s)"):format(artist, album, mbid, asin))
	d = mbcoverart.download_cover_art(artist, album, mbid, asin)

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
	if not art_file and DOWNLOAD_COVER_ART then
		art_file = download_cover_art_to_cache(artist, album, album_mbid)
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
		for _, v in ipairs(keys) do
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
