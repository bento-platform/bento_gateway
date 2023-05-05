local ngx = ngx
local require = require

local cjson = require("cjson")
local http = require("resty.http")
local redis = require("resty.redis")


-- START FUNCTION DEFINITIONS -----------------------------------------------------------
local uncached_response = function (status, mime, message)
  -- Helper method to return uncached responses directly from the proxy without
  -- needing an underlying service.
  ngx.status = status
  if mime then ngx.header["Content-Type"] = mime end
  ngx.header["Cache-Control"] = "no-store"
  ngx.header["Pragma"] = "no-cache"  -- Backwards-compatibility for no-cache
  if message then ngx.say(message) end
  ngx.exit(status)
end

local err_missing_bearer = function ()
  uncached_response(
    ngx.HTTP_FORBIDDEN,
    "application/json",
    cjson.encode({message="Forbidden", tag="missing bearer token"})
  )
end

local err_redis = function(tag)
  uncached_response(ngx.HTTP_INTERNAL_SERVER_ERROR,
    "application/json",
    cjson.encode({message=red_err, tag=tag}))
end
-- END FUNCTION DEFINITIONS -----–-----–-----–-----–-----–-----–-----–-----–-----–-------


-- START REDIS CONNECTION PART ----------------------------------------------------------
local REDIS_CONNECTION_STRING = "bentov2-redis:6379"
local REDIS_CONTAINER_NAME = os.getenv("BENTOV2_REDIS_CONTAINER_NAME")
if REDIS_CONTAINER_NAME ~= nil and REDIS_CONTAINER_NAME ~= "" then
  -- Default / backwards-compatibility before this was configurable:
  REDIS_CONNECTION_STRING = REDIS_CONTAINER_NAME  -- No port specified, will use default port
end

local REDIS_SOCKET
local REDIS_HOST
local REDIS_PORT

if REDIS_CONNECTION_STRING:match("^unix") then
  REDIS_SOCKET = REDIS_CONNECTION_STRING
else  -- Treat as host/port
  -- Format: localhost:6379
  local port_sep = REDIS_CONNECTION_STRING:find(":")
  if port_sep == nil then
    REDIS_HOST = REDIS_CONNECTION_STRING
    REDIS_PORT = 6379  -- Default Redis port
  else
    REDIS_HOST = REDIS_CONNECTION_STRING:sub(1, port_sep-1)
    REDIS_PORT = tonumber(REDIS_CONNECTION_STRING:sub(port_sep+1, #REDIS_CONNECTION_STRING))
  end
end

-- Create an un-connected Redis object
local red_ok
local red, red_err = redis:new()
if red_err then
  uncached_response(
    ngx.HTTP_INTERNAL_SERVER_ERROR,
    "application/json",
    cjson.encode({message=red_err, tag="ott redis conn", user_role=nil}))
end

-- Function to handle common Redis connection tasks
local redis_connect = function ()
  if REDIS_SOCKET then
    return red:connect(REDIS_SOCKET)
  else
    return red:connect(REDIS_HOST, REDIS_PORT)
  end
end
-- END REDIS CONNECTION PART ------------------------------------------------------------


-- BEGIN AUTHORIZATION LOGIC ------------------------------------------------------------

-- TODO: check redis cache for OIDC configuration data; otherwise, fetch it.

-- Check bearer token if set
-- Adapted from https://github.com/zmartzone/lua-resty-openidc/issues/266#issuecomment-542771402
local auth_header = ngx.req.get_headers()["Authorization"]
if auth_header and auth_header:match("^Bearer .+") then
  red_ok, red_err = redis_connect()
  if red_err then  -- Error occurred while connecting to Redis
    err_redis("redis conn")
    goto script_end
  end

  -- A Bearer auth header is set, check it is valid using the introspection endpoint
  -- IMPORTANT NOTE: Technically we (as application developers) SHOULD NOT have access to this endpoint.
  --  We are just using it as a way to transition to checking JWTs ourselves in each service.
  local c = http.new()
  local res, err = c:request_uri("TODO", {  -- TODO
    method="POST",
    body="token=" .. auth_header:sub(auth_header:find(" ") + 1),
    headers={
      ["Content-Type"] = "application/x-www-form-urlencoded"
    },
  })

  -- TODO: handle token response
else
  err_missing_bearer()
end
