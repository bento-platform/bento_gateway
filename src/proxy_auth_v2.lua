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

local err_forbidden = function (detail)
  uncached_response(
    ngx.HTTP_FORBIDDEN,
    "application/json",
    cjson.encode({message="Forbidden", detail=detail})
  )
end

local err_500_and_log = function (detail, err)
  ngx.log(ngx.ERR, detail, " err: ", err)
  uncached_response(ngx.HTTP_INTERNAL_SERVER_ERROR,
    "application/json",
    cjson.encode({message="Internal server error", detail=detail}))
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

local bento_debug = os.getenv("BENTO_DEBUG")
bento_debug = bento_debug == "true" or bento_debug == "True" or bento_debug == "1"
local ssl_verify = not bento_debug

local c = http.new()
local res
local err

-- Check redis cache for OpenID configuration data; otherwise, fetch it.

red_ok, red_err = redis_connect()
if red_err then
  err_500_and_log("error opening redis connection", red_err)
  goto script_end
end

local oidc_config
res, red_err = red:get("bento_gateway:openid-config")
if red_err then
  err_500_and_log("error fetching openid-config from redis", red_err)
  goto script_end
end
if res == ngx.null then
  local OPENID_CONFIG_URL = os.getenv("BENTO_OPENID_CONFIG_URL")
  if OPENID_CONFIG_URL == nil then
    err_500_and_log("unset OpenID configuration URL", "OPENID_CONFIG_URL == nil")
    goto script_end
  end

  -- Fetch OpenID configuration - if in debug mode, don't verify the SSL certificate.
  res, err = c:request_uri(OPENID_CONFIG_URL, {method="GET", ssl_verify=ssl_verify})
  if err then
    err_500_and_log("error in .../openid-configuration call", err)
    goto script_end
  end
  local body = res.body
  red_ok, red_err = red:set("bento_gateway:openid-config", body)
  if red_err then
    err_500_and_log("error caching openid-config to redis", red_err)
    goto script_end
  end
  oidc_config = cjson.decode(body)
else
  oidc_config = cjson.decode(res)
end

-- Check bearer token if set
-- Adapted from https://github.com/zmartzone/lua-resty-openidc/issues/266#issuecomment-542771402
local auth_header = ngx.req.get_headers()["Authorization"]
if auth_header and auth_header:match("^Bearer .+") then
  red_ok, red_err = redis_connect()
  if red_err then  -- Error occurred while connecting to Redis
    err_500_and_log("error connecting to redis", red_err)
    goto script_end
  end

  -- A Bearer auth header is set, check it is valid using the introspection endpoint
  -- IMPORTANT NOTE: Technically we (as application developers) SHOULD NOT have access to this endpoint.
  --  We are just using it as a way to transition to checking JWTs ourselves in each service.
  res, err = c:request_uri(oidc_config["introspection_endpoint"], {
    method="POST",
    ssl_verify=ssl_verify,
    body="token=" .. auth_header:sub(auth_header:find(" ") + 1),
    headers={
      ["Content-Type"] = "application/x-www-form-urlencoded"
    },
  })

  if err then
    err_500_and_log("error in introspection call", err)
    goto script_end
  end

  local body
  body, err = cjson.decode(body)
  if err then
    err_500_and_log("error reading introspection endpoint response", err)
    goto script_end
  end

  if body["error"] ~= nil then
    ngx.log(ngx.ERR, "error from introspection endpoint", body["error"], body["error_description"])
    err_forbidden("invalid token")  -- generic error - don't reveal too much
    goto script_end
  end

  if not body["active"] then
    err_forbidden("inactive token - DNE or expired or bad client")
    goto script_end
  end

  local client_id = os.getenv("CLIENT_ID")
  if body["client_id"] ~= client_id then
    err_forbidden("token has wrong client ID")
    goto script_end
  end

  -- If the script gets here, no error occurred and we can pass the request through
  ngx.req.set_header("X-User", body["sub"])
  -- Hard-coded since that is what was in proxy_auth v1 as well for Dockerized version of Bento:
  ngx.req.set_header("X-User-Role", "admin")
  ngx.req.set_header("X-Authorization", auth_header)
else
  err_forbidden("missing bearer token")
  goto script_end
end

-- If an unrecoverable error occurred, it will jump here to skip everything and
-- avoid trying to execute code while in an invalid state.
::script_end::
