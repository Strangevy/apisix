local log_util          = require("apisix.utils.log-util")
local core              = require("apisix.core")
local lrucache          = require("resty.lrucache")
local expr              = require("resty.expr.v1")
local pb                = require("pb")
local proto             = require("apisix.plugins.grpc-transcode.proto")
local ngx               = ngx
local io_open           = io.open
local req_get_body_data = ngx.req.get_body_data



local plugin_name = "file-logger-cst"


local schema = {
    type = "object",
    properties = {
        path = {
            description = "Path of save file log",
            type = "string"
        },
        print_count_of_req = {
            description = "Limit the number of prints in the same worker",
            type = "number",
            minimum = 1
        },
        match = {
            description = "Like traffic-split rules.match.vars: "
                .. " https://apisix.apache.org/zh/docs/apisix/plugins/traffic-split/#%E5%B1%9E%E6%80%A7",
            type = "array"
        },
        proto_id = {
            type = "string"
        },
        request_type = {
            type = "string"
        },
        response_type = {
            type = "string"
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
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if conf.match then
        local ok, err = expr.new(conf.match)
        if not ok then
            return false, "failed to validate the 'match' expression: " .. err
        end
    end

    return true
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

function _M.init()
    proto.init()
end

local function print_proto(conf)
    local proto_obj, err = proto.fetch(conf.roto_id)
    if not proto_obj then
        core.log.error("proto load error: ", err)
        return
    end

    local body = req_get_body_data()

    pb.state(proto_obj.pb_state)

    local decode = pb.decode(conf.request_type, body)
    core.log.error(core.json.encode(decode))
end

local function check_match(match)
    if not match then
        return true
    end

    local expr, err = expr.new(match)
    if err then
        core.log.error("match expression does not match: ", err)
        return false, err
    end

    if not expr:eval(match) then
        return false, "not match"
    end

    return true
end

function _M.log(conf, ctx)
    -- demo protocol bufferx
    -- print_proto(conf)
    local is_match = check_match(conf.match)
    if not is_match then
        return
    end
    if not conf.print_count_of_req or c:get(lru_key) % conf.print_count_of_req == 0 then
        c:set(lru_key, c:get(lru_key) + 1)
        print(conf)
    end
end

return _M
