-- mpvSockets, one socket per instance, removes socket on exit
-- socket name:  {timestamp}-{pid}
-- socket dir: $MPVIPCBASE if set, otherwise /tmp/mpvSockets

local utils = require 'mp.utils'
if not utils.getpid then
    utils.getpid = require 'posix.unistd'.getpid
end


local function get_temp_path()
    local directory_seperator = package.config:match("([^\n]*)\n?")
    local example_temp_file_path = os.tmpname()

    -- remove generated temp file
    pcall(os.remove, example_temp_file_path)

    local seperator_idx = example_temp_file_path:reverse():find(directory_seperator)
    local temp_path_length = #example_temp_file_path - seperator_idx

    return example_temp_file_path:sub(1, temp_path_length)
end


function join_paths(...)
    local arg={...}
    path = ""
    for i,v in ipairs(arg) do
        path = utils.join_path(path, tostring(v))
    end
    return path
end


function get_sock_file()
    local pid = utils.getpid()
    --print(pid)
    --print("pid: " .. pid)
    return os.time() .. '-' .. (pid or "0")
end


function get_sock_dir()
    local my_dir = os.getenv("MPVIPCBASE")
    --print(my_dir)
    if my_dir then
        return my_dir
    end
    return join_paths(get_temp_path(), "mpvSockets")
end


local ipcServer = get_sock_dir()
os.execute("mkdir -p -- " .. ipcServer)

local name = get_sock_file()
ipcServer = join_paths(ipcServer, name)
--print(ipcServer)

mp.set_property("options/input-ipc-server", ipcServer)
mp.register_event("shutdown", function() os.remove(ipcServer); end)
