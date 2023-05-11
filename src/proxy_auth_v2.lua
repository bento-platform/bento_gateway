local ngx = ngx
local require = require

local cjson = require("cjson")
local http = require("resty.http")
local jwt = require("resty.jwt")
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

-- Check bearer token if set
-- Adapted from https://github.com/zmartzone/lua-resty-openidc/issues/266#issuecomment-542771402
local auth_header = ngx.req.get_headers()["Authorization"]
if auth_header and auth_header:match("^Bearer .+") then
  local authz_service_url = os.getenv("BENTO_AUTHZ_SERVICE_URL")
  local req_body = cjson.encode({
    requested_resource={everything=True},
    required_permissions={"view:private_portal"}
  })
  res, err = c:request_uri(authz_service_url .. "policy/evaluate", {
    method="POST",
    body=req_body,
    headers={
      ["Content-Type"] = "application/json",
      ["Authorization"] = auth_header,
    },
    ssl_verify=ssl_verify,
  })

  if err then
    err_500_and_log("error in authorization service call | req: " .. req_body, err)
    goto script_end
  end

  if res.status ~= 200 then
    -- Bad response
    err_500_and_log(
      "bad status from authorization service call: " .. res.status .. " req: " .. req_body, res.body)
    goto script_end
  end

  if not cjson.decode(res.body or '{"result": false}')["result"] then
    -- Not allowed
    err_forbidden("forbidden")
    goto script_end
  end

  local decoded_jwt = jwt:load_jwt(auth_header:sub(auth_header:find(" ") + 1))

  -- If the script gets here, no error occurred and we can pass the request through
  ngx.req.set_header("X-User", decoded_jwt["payload"]["sub"])
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
