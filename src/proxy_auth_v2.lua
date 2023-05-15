local ngx = ngx
local require = require

local cjson = require("cjson")
local http = require("resty.http")
local jwt = require("resty.jwt")
local redis = require("resty.redis")


-- START FUNCTION DEFINITIONS -----------------------------------------------------------
local NGX_NULL = ngx.null
local ngx_null_to_nil = function(v)
  if v == NGX_NULL then
    return nil
  else
    return v
  end
end

local invalidate_ott = function(redis_conn, token)
  -- Helper method to invalidate a one-time token, given a connection to the
  -- Redis instance being used and the token in question
  redis_conn:hdel("bento_ott:expiry", token)
  redis_conn:hdel("bento_ott:scope", token)
  redis_conn:hdel("bento_ott:user_id", token)
  redis_conn:hdel("bento_ott:user_role", token)
end

local invalidate_tt = function(redis_conn, token)
  -- Helper method to invalidate a one-time token, given a connection to the
  -- Redis instance being used and the token in question
  redis_conn:hdel("bento_tt:expiry", token)
  redis_conn:hdel("bento_tt:scope", token)
  redis_conn:hdel("bento_tt:user_id", token)
  redis_conn:hdel("bento_tt:user_role", token)
end

local uncached_response = function(status, mime, message)
  -- Helper method to return uncached responses directly from the proxy without
  -- needing an underlying service.
  ngx.status = status
  if mime then
    ngx.header["Content-Type"] = mime
  end
  ngx.header["Cache-Control"] = "no-store"
  ngx.header["Pragma"] = "no-cache"  -- Backwards-compatibility for no-cache
  if message then
    ngx.say(message)
  end
  ngx.exit(status)
end

local err_invalid_req_body = function()
  uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
    cjson.encode({ message = "Missing or invalid body", detail = "invalid body" }))
end

local err_invalid_method = function()
  uncached_response(ngx.HTTP_NOT_ALLOWED, "application/json",
    cjson.encode({ message = "Method not allowed", detail = "invalid method" }))
end

local err_forbidden = function(detail)
  uncached_response(
    ngx.HTTP_FORBIDDEN,
    "application/json",
    cjson.encode({ message = "Forbidden", detail = detail })
  )
end

local err_500_and_log = function(detail, err)
  ngx.log(ngx.ERR, detail, " err: ", err)
  uncached_response(ngx.HTTP_INTERNAL_SERVER_ERROR,
    "application/json",
    cjson.encode({ message = "Internal server error", detail = detail }))
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
else
  -- Treat as host/port
  -- Format: localhost:6379
  local port_sep = REDIS_CONNECTION_STRING:find(":")
  if port_sep == nil then
    REDIS_HOST = REDIS_CONNECTION_STRING
    REDIS_PORT = 6379  -- Default Redis port
  else
    REDIS_HOST = REDIS_CONNECTION_STRING:sub(1, port_sep - 1)
    REDIS_PORT = tonumber(REDIS_CONNECTION_STRING:sub(port_sep + 1, #REDIS_CONNECTION_STRING))
  end
end

-- Create an un-connected Redis object
local red_ok
local red, red_err = redis:new()
if red_err then
  uncached_response(
    ngx.HTTP_INTERNAL_SERVER_ERROR,
    "application/json",
    cjson.encode({ message = red_err, tag = "ott redis conn", user_role = nil }))
end

-- Function to handle common Redis connection tasks
local redis_connect = function()
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

local user_id
local user_role

local req_headers = ngx.req.get_headers()

local ott_header = req_headers["X-OTT"]
local tt_header = req_headers["X-TT"]
if ott_header and not URI:match("^/api/auth") then
  -- Cannot use a one-time token to bootstrap generation of more one-time
  -- tokens or invalidate existing ones
  -- URIs do not include URL parameters, so this is safe from non-exact matches

  -- The auth namespace check should theoretically be handled by the scope
  -- validation anyway, but manually check it as a last resort

  red_ok, red_err = redis_connect()
  if red_err then
    -- Error occurred while connecting to Redis
    err_500_and_log("redis conn", red_err)
    goto script_end
  end

  -- TODO: Error handling for each command? Maybe overkill

  -- Fetch all token data from the Redis store and subsequently delete it
  local expiry = tonumber(red:hget("bento_ott:expiry", ott_header), 10) or nil
  local scope = ngx_null_to_nil(red:hget("bento_ott:scope", ott_header))
  user_id = ngx_null_to_nil(red:hget("bento_ott:user_id", ott_header))
  user_role = ngx_null_to_nil(red:hget("bento_ott:user_role", ott_header))

  red:init_pipeline(5)
  invalidate_ott(red, ott_header)  -- 5 pipeline actions
  red:commit_pipeline()

  -- Update NGINX time (which is cached)
  -- This is slow, so OTTs should not be over-used in situations where there's
  -- a more performant way that likely makes more sense anyway.
  ngx.update_time()

  -- Check token validity
  if expiry == nil then
    -- Token cannot be found in the Redis store
    uncached_response(ngx.HTTP_FORBIDDEN, "application/json",
      cjson.encode({ message = "Invalid one-time token", tag = "ott invalid" }))
  elseif expiry < ngx.time() then
    -- Token expiry date is in the past, so it is no longer valid
    uncached_response(ngx.HTTP_FORBIDDEN, "application/json",
      cjson.encode({ message = "Expired one-time token", tag = "ott expired" }))
  elseif URI:sub(1, #scope) ~= scope then
    -- Invalid call made with the token (out of scope)
    -- We're harsh here and still delete the token out of security concerns
    uncached_response(ngx.HTTP_FORBIDDEN, "application/json",
      cjson.encode({
        message = "Out-of-scope one-time token (scope: " .. scope .. ", URI prefix: " .. URI:sub(1, #scope) .. ")",
        detail = "ott out of scope" }))
  end

  -- No nested auth header is set; OTTs cannot be used to bootstrap a full bearer token

  -- Put Redis connection into a keepalive pool for 30 seconds
  red_ok, red_err = red:set_keepalive(30000, 100)
  if red_err then
    err_500_and_log("redis keepalive failed", red_err)
    goto script_end
  end
elseif tt_header and not URI:match("^/api/auth") then
  -- Cannot use a one-time token to bootstrap generation of more one-time
  -- tokens or invalidate existing ones
  -- URIs do not include URL parameters, so this is safe from non-exact matches

  -- The auth namespace check should theoretically be handled by the scope
  -- validation anyway, but manually check it as a last resort

  red_ok, red_err = redis_connect()
  if red_err then
    -- Error occurred while connecting to Redis
    err_500_and_log("redis conn", red_err)
    goto script_end
  end

  -- TODO: Error handling for each command? Maybe overkill

  -- Fetch all token data from the Redis store and subsequently delete it
  local expiry = tonumber(red:hget("bento_tt:expiry", tt_header), 10) or nil
  local scope = ngx_null_to_nil(red:hget("bento_tt:scope", tt_header))
  user_id = ngx_null_to_nil(red:hget("bento_tt:user_id", tt_header))
  user_role = ngx_null_to_nil(red:hget("bento_tt:user_role", tt_header))


  -- Update NGINX time (which is cached)
  -- This is slow, so OTTs should not be over-used in situations where there's
  -- a more performant way that likely makes more sense anyway.
  ngx.update_time()

  -- Check token validity
  if expiry == nil then
    -- Token cannot be found in the Redis store
    uncached_response(ngx.HTTP_FORBIDDEN, "application/json",
      cjson.encode({ message = "Invalid temporary token", tag = "tt invalid", user_role = nil }))
  elseif expiry < ngx.time() then
    -- Token expiry date is in the past, so it is no longer valid
    red:init_pipeline(5)
    invalidate_tt(red, tt_header)  -- 5 pipeline actions
    red:commit_pipeline()

    uncached_response(ngx.HTTP_FORBIDDEN, "application/json",
      cjson.encode({ message = "Expired temporary token", tag = "tt expired", user_role = nil }))
  elseif URI:sub(1, #scope) ~= scope then
    -- Invalid call made with the token (out of scope)
    -- We're harsh here and still delete the token out of security concerns
    uncached_response(ngx.HTTP_FORBIDDEN, "application/json",
      cjson.encode({
        message = "Out-of-scope temporary token (scope: " .. scope .. ", URI prefix: " .. URI:sub(1, #scope) .. ")",
        tag = "tt out of scope",
        user_role = nil }))
  end

  -- No nested auth header is set; OTTs cannot be used to bootstrap a full bearer token

  -- Put Redis connection into a keepalive pool for 30 seconds
  red_ok, red_err = red:set_keepalive(30000, 100)
  if red_err then
    err_500_and_log("redis keepalive failed", red_err)
    goto script_end
  end
else
  -- Check bearer token if set
  -- Adapted from https://github.com/zmartzone/lua-resty-openidc/issues/266#issuecomment-542771402
  local auth_header = ngx.req.get_headers()["Authorization"]
  if auth_header and auth_header:match("^Bearer .+") then
    local authz_service_url = os.getenv("BENTO_AUTHZ_SERVICE_URL")
    local required_permissions = { "view:private_portal" }
    setmetatable(required_permissions, cjson.array_mt)
    local req_body = cjson.encode({
      requested_resource = { everything = true },
      required_permissions = required_permissions,
    })
    res, err = c:request_uri(authz_service_url .. "policy/evaluate", {
      method = "POST",
      body = req_body,
      headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = auth_header,
      },
      ssl_verify = ssl_verify,
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

    -- Hard-coded since that is what was in proxy_auth v1 as well for Dockerized version of Bento:
    user_id = decoded_jwt["payload"]["sub"]
    user_role = "owner"

    -- If the script gets here, no error occurred and we can pass the request through
    ngx.req.set_header("X-User", user_id)
    -- Hard-coded since that is what was in proxy_auth v1 as well for Dockerized version of Bento:
    ngx.req.set_header("X-User-Role", user_role)
    ngx.req.set_header("X-Authorization", auth_header)


    -- TEMPORARY TOKEN HANDLING LOGIC -------------------------------------------------------

    -- Cache commonly-used ngx.var.uri and ngx.var.request_method to save expensive access calls
    local URI = ngx.var.original_uri or ngx.var.uri or ""
    local REQUEST_METHOD = ngx.var.request_method or "GET"

    local ONE_TIME_TOKENS_GENERATE_PATH = "/api/auth/ott/generate"
    local ONE_TIME_TOKENS_INVALIDATE_PATH = "/api/auth/ott/invalidate"
    local ONE_TIME_TOKENS_INVALIDATE_ALL_PATH = "/api/auth/ott/invalidate_all"

    local TEMP_TOKENS_GENERATE_PATH = "/api/auth/tt/generate"

    if URI == ONE_TIME_TOKENS_GENERATE_PATH then
      -- Endpoint: POST /api/auth/ott/generate
      --   Generates one or more one-time tokens for asynchronous authorization
      --   purposes if user is authenticated; otherwise returns a 401 Forbidden error.
      --   Called with a POST body (in JSON format) of: (for example)
      --     {"scope": "/api/some_service/", "tokens": 5}
      --   This will generate 5 one-time-use tokens that are only valid on URLs in
      --   the /api/some_service/ namespace.
      --   Scopes cannot be outside /api/ or in /api/auth

      if REQUEST_METHOD ~= "POST" then
        err_invalid_method()
        goto script_end
      end

      ngx.req.read_body()  -- Read the request body into memory
      local ngx_req_body = cjson.decode(ngx.req.get_body_data() or "null")
      if type(ngx_req_body) ~= "table" then
        err_invalid_req_body()
        goto script_end
      end

      local scope = ngx_req_body["scope"]
      if not scope or type(scope) ~= "string" then
        uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
          cjson.encode({ message = "Missing or invalid token scope", tag = "invalid scope", user_role = user_role }))
        goto script_end
      end

      -- Validate that the scope asked for is reasonable
      --   - Must be in a /api/[a-zA-Z0-9]+/ namespace
      --   - Cannot be specific to the auth namespace

      if not scope:match("^/api/%a[%w-_]*/") or scope:match("^/api/auth") then
        uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
          cjson.encode({ message = "Bad token scope", tag = "bad scope", user_role = user_role }))
        goto script_end
      end

      local n_tokens = math.max(ngx_req_body["number"] or 1, 1)

      -- Don't let a user request more than 30 OTTs at a time
      if n_tokens > 30 then
        uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
          cjson.encode({ message = "Too many OTTs requested", tag = "too many tokens", user_role = user_role }))
        goto script_end
      end

      red_ok, red_err = redis_connect()
      if red_err then
        err_500_and_log("redis conn", red_err)
        goto script_end
      end

      -- Update NGINX internal time cache
      ngx.update_time()

      local new_token
      local new_tokens = {}

      -- Generate n_tokens new tokens
      red:init_pipeline(5 * n_tokens)
      for _ = 1, n_tokens do
        -- Generate a new token (using OpenSSL via lua-resty-random), 128 characters long
        -- Does not use the token method, since that does not use OpenSSL
        new_token = str.to_hex(random.bytes(64))
        -- TODO: RANDOM CAN RETURN NIL, HANDLE THIS
        table.insert(new_tokens, new_token)
        red:hset("bento_ott:expiry", new_token, ngx.time() + 604800)  -- Set expiry to current time + 7 days
        red:hset("bento_ott:scope", new_token, scope)
        red:hset("bento_ott:user_id", new_token, user_id)
        red:hset("bento_ott:user_role", new_token, user_role)
      end
      red:commit_pipeline()

      -- Put Redis connection into a keepalive pool for 30 seconds
      red_ok, red_err = red:set_keepalive(30000, 100)
      if red_err then
        err_500_and_log("redis keepalive failed", red_err)
        -- TODO: Do we need to invalidate the tokens here? They aren't really guessable anyway
        goto script_end
      end

      -- Return the newly-generated tokens to the requester
      uncached_response(ngx.HTTP_OK, "application/json", cjson.encode(new_tokens))
    elseif URI == TEMP_TOKENS_GENERATE_PATH then
      -- TODO: refactor (deduplicate)
      -- Endpoint: POST /api/auth/tt/generate
      --   Generates one or more one-time tokens for asynchronous authorization
      --   purposes if user is authenticated; otherwise returns a 401 Forbidden error.
      --   Called with a POST body (in JSON format) of: (for example)
      --     {"scope": "/api/some_service/", "tokens": 5}
      --   This will generate 5 one-time-use tokens that are only valid on URLs in
      --   the /api/some_service/ namespace.
      --   Scopes cannot be outside /api/ or in /api/auth

      if REQUEST_METHOD ~= "POST" then
        err_invalid_method()
        goto script_end
      end

      ngx.req.read_body()  -- Read the request body into memory
      local ngx_req_body = cjson.decode(ngx.req.get_body_data() or "null")
      if type(ngx_req_body) ~= "table" then
        err_invalid_req_body()
        goto script_end
      end

      local scope = ngx_req_body["scope"]
      if not scope or type(scope) ~= "string" then
        uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
          cjson.encode({ message = "Missing or invalid token scope", tag = "invalid scope" }))
        goto script_end
      end

      -- Validate that the scope asked for is reasonable
      --   - Must be in a /api/[a-zA-Z0-9]+/ namespace
      --   - Cannot be specific to the auth namespace

      if not scope:match("^/api/%a[%w-_]*/") or scope:match("^/api/auth") then
        uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
          cjson.encode({ message = "Bad token scope", tag = "bad scope" }))
        goto script_end
      end

      local n_tokens = math.max(ngx_req_body["number"] or 1, 1)

      -- Don't let a user request more than 30 TTs at a time
      if n_tokens > 30 then
        uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
          cjson.encode({ message = "Too many TTs requested", tag = "too many tokens" }))
        goto script_end
      end

      red_ok, red_err = redis_connect()
      if red_err then
        err_500_and_log("redis conn", red_err)
        goto script_end
      end

      -- Update NGINX internal time cache
      ngx.update_time()

      local new_token
      local new_tokens = {}

      -- Generate n_tokens new tokens
      red:init_pipeline(5 * n_tokens)
      for _ = 1, n_tokens do
        -- Generate a new token (using OpenSSL via lua-resty-random), 128 characters long
        -- Does not use the token method, since that does not use OpenSSL
        new_token = str.to_hex(random.bytes(64))
        -- TODO: RANDOM CAN RETURN NIL, HANDLE THIS
        table.insert(new_tokens, new_token)
        red:hset("bento_tt:expiry", new_token, ngx.time() + 86400)  -- Set expiry to current time + 1 day (TODO: make flexible?)
        red:hset("bento_tt:scope", new_token, scope)
        red:hset("bento_tt:user_id", new_token, user_id)
        red:hset("bento_tt:user_role", new_token, user_role)
      end
      red:commit_pipeline()

      -- Put Redis connection into a keepalive pool for 30 seconds
      red_ok, red_err = red:set_keepalive(30000, 100)
      if red_err then
        err_500_and_log("redis keepalive failed", red_err)
        -- TODO: Do we need to invalidate the tokens here? They aren't really guessable anyway
        goto script_end
      end

      -- Return the newly-generated tokens to the requester
      uncached_response(ngx.HTTP_OK, "application/json", cjson.encode(new_tokens))
    elseif URI == ONE_TIME_TOKENS_INVALIDATE_PATH then
      -- Endpoint: DELETE /api/auth/ott/invalidate
      --   Invalidates a token passed in the request body (format: {"token": "..."}) if the
      --   supplied token exists. This endpoint is idempotent, and will return 204 (assuming
      --   nothing went wrong on the server) even if the token did not exist. Regardless, the
      --   end state is that the supplied token is guaranteed not to be valid anymore.

      if REQUEST_METHOD ~= "DELETE" then
        err_invalid_method()
        goto script_end
      end

      ngx.req.read_body()  -- Read the request body into memory
      local ngx_req_body = cjson.decode(ngx.req.get_body_data() or "null")
      if type(ngx_req_body) ~= "table" then
        err_invalid_req_body()
        goto script_end
      end

      local token = ngx_req_body["token"]
      if not token or type(token) ~= "string" then
        uncached_response(ngx.HTTP_BAD_REQUEST, "application/json",
          cjson.encode({ message = "Missing or invalid token", tag = "invalid token" }))
        goto script_end
      end

      red_ok, red_err = redis_connect()
      if red_err then
        err_500_and_log("redis conn", red_err)
        goto script_end
      end

      invalidate_ott(red, token)

      -- Put Redis connection into a keepalive pool for 30 seconds
      red_ok, red_err = red:set_keepalive(30000, 100)
      if red_err then
        err_500_and_log("redis keepalive failed", red_err)
        goto script_end
      end

      -- We're good to respond in the affirmative
      uncached_response(ngx.HTTP_NO_CONTENT)
    elseif URI == ONE_TIME_TOKENS_INVALIDATE_ALL_PATH then
      -- Endpoint: DELETE /api/auth/ott/invalidate_all
      --   Invalidates all one-time use tokens in the Redis store. This endpoint is
      --   idempotent, and will return 204 (assuming nothing went wrong on the server) even if
      --   no tokens currently exist. Regardless, the end state is that all OTTs are
      --   guaranteed not to be valid anymore.

      if REQUEST_METHOD ~= "DELETE" then
        err_invalid_method()
        goto script_end
      end

      red_ok, red_err = redis_connect()
      if red_err then
        err_500_and_log("redis conn", red_err)
        goto script_end
      end

      red:init_pipeline(5)
      red:del("bento_ott:expiry")
      red:del("bento_ott:scope")
      red:del("bento_ott:user_id")
      red:del("bento_ott:user_role")
      red:commit_pipeline()

      -- Put Redis connection into a keepalive pool for 30 seconds
      red_ok, red_err = red:set_keepalive(30000, 100)
      if red_err then
        err_500_and_log("redis keepalive failed", red_err)
        goto script_end
      end

      -- We're good to respond in the affirmative
      uncached_response(ngx.HTTP_NO_CONTENT)

    end

  else
    err_forbidden("missing bearer token")
    goto script_end
  end
end

-- If an unrecoverable error occurred, it will jump here to skip everything and
-- avoid trying to execute code while in an invalid state.
:: script_end ::
