local log_util = require("apisix.utils.log-util")
local core     = require("apisix.core")
local lrucache = require("resty.lrucache")
local ngx      = ngx
local io_open  = io.open


local plugin_name = "file-logger-cst"


local schema = {
    type = "object",
    properties = {
        path = {
            type = "string"
        },
        print_count_of_req = {
            type = "number",
            minimum = 1
        },
        match = {
            description = "like traffic-split rules.match.vars: "
                .. " https://apisix.apache.org/zh/docs/apisix/plugins/traffic-split/#%E5%B1%9E%E6%80%A7",
            type = "array"
        },
    },
    required = { "path" }
}


local _M = {
    version = 0.1,
    priority = 3999,
    name = plugin_name,
    schema = schema
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function write_file_data(conf, log_message)
    local msg = core.json.encode(log_message)

    local file, err = io_open(conf.path, 'a+')

    if not file then
        core.log.error("failed to open file: ", conf.path, ", error info: ", err)
    else
        local ok, err = file:write(msg, '\n')
        if not ok then
            core.log.error("failed to write file: ", conf.path, ", error info: ", err)
        else
            file:flush()
        end

        file:close()
    end
end

local c, err = lrucache.new(1)

if not c then
    return error("failed to create the cache: " .. (err or "unknown"))
end

local lru_key = "req_count"
c:set(lru_key, 0)

local function print(conf)
    conf.include_req_body = "on";
    local entry = log_util.get_full_log(ngx, conf)
    write_file_data(conf, entry)
end

function _M.log(conf, ctx)
    if not conf.print_count_of_req or c:get(lru_key) % conf.print_count_of_req == 0 then
        c:set(lru_key, c:get(lru_key) + 1)
        print(conf)
    end
end

return _M
