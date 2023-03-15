local ngx = ngx
local require = require

local cjson = require("cjson")
local openidc = require("resty.openidc")

-- Helpers
local stringtoboolean={ ["true"]=true, ["false"]=false }

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

local OIDC_CALLBACK_PATH = "/api/auth/callback"
local OIDC_CALLBACK_PATH_NO_SLASH = OIDC_CALLBACK_PATH:sub(2, #OIDC_CALLBACK_PATH)
local SIGN_OUT_PATH = "/api/auth/sign-out"

local user
local user_id
local nested_auth_header


-- Load auth configuration for setting up lua-resty-oidconnect from env
local CHORD_DEBUG = stringtoboolean[os.getenv("CHORD_DEBUG")]

-- Cannot use "or" shortcut, otherwise would always be true
local CHORD_PERMISSIONS = os.getenv("CHORD_PERMISSIONS")
if CHORD_PERMISSIONS == nil then CHORD_PERMISSIONS = true end

-- If in production, validate the SSL certificate if HTTPS is being used (for
-- non-Lua folks, this is a ternary - ssl_verify = !chord_debug)
local opts_ssl_verify = "no"
-- CHORD_DEBUG and "no" or "yes"

-- If in production, enforce CHORD_URL as the base for redirect
local opts_redirect_uri = OIDC_CALLBACK_PATH
if not CHORD_DEBUG then
  opts_redirect_uri = os.getenv("CBIOPORTAL_URL") .. OIDC_CALLBACK_PATH_NO_SLASH
end

-- defines URL the client will be redirected to after the `/api/auth/sign-out` is
-- hit and strips the session. This URL should port to the IdP's `.../logout` handle
local opts_redirect_after_logout_uri = os.getenv("REDIRECT_AFTER_LOGOUT_URI")

local opts = {
  redirect_uri = opts_redirect_uri,
  logout_path = SIGN_OUT_PATH,
  redirect_after_logout_uri = opts_redirect_after_logout_uri,
  redirect_after_logout_with_id_token_hint = false,
  post_logout_redirect_uri = os.getenv("CBIOPORTAL_URL"),

  discovery = os.getenv("OIDC_DISCOVERY_URI"),

  client_id = os.getenv("CLIENT_ID"),
  client_secret = os.getenv("CLIENT_SECRET"),

  -- Default token_endpoint_auth_method to client_secret_basic
  token_endpoint_auth_method = os.getenv("TOKEN_ENDPOINT_AUTH_METHOD") or "client_secret_basic",

  accept_none_alg = false,
  accept_unsupported_alg = false,
  ssl_verify = opts_ssl_verify,

  -- Disable keepalive to try to prevent some "lost access token" issues with the OP
  -- See https://github.com/zmartzone/lua-resty-openidc/pull/307 for details
  keepalive = "no",

  -- TODO: Re-enable this if it doesn't cause sign-out bugs, since it's more secure
  -- refresh_session_interval = 600,

  iat_slack = 120,
  -- access_token_expires_in should be shorter than $session_cookie_lifetime otherwise will never be called
  -- Keycloak defaults to 1-minute access tokens
  access_token_expires_in = 60,
  access_token_expires_leeway = 15,
  renew_access_token_on_expiry = true,
}

-- Check bearer token if set
-- Adapted from https://github.com/zmartzone/lua-resty-openidc/issues/266#issuecomment-542771402
local auth_header = ngx.req.get_headers()["Authorization"]
if auth_header and auth_header:match("^Bearer .+") then
  -- A Bearer auth header is set, use it instead of session through introspection
  local res, err = openidc.introspect(opts)
  if err == nil and res.active then
    -- If we have a valid access token, try to get the user info
    --   - Slice out the token from the Authorization header
    user, err = openidc.call_userinfo_endpoint(
            opts, auth_header:sub(auth_header:find(" ") + 1))
    if err == nil then
      -- User profile fetch was successful, grab the values
      user_id = user.sub
      nested_auth_header = auth_header
    end
  end

  -- Log any errors that occurred above
  if err then ngx.log(ngx.ERR, err) end
else
  -- If no Bearer token is set, use session cookie to get authentication information
  local res, err, _, session = openidc.authenticate(
          opts, ngx.var.request_uri, nil)  -- Nil means redirect to sign-in page
  if res == nil or err then  -- Authentication wasn't successful
    -- Authentication wasn't successful; clear the session
    if session ~= nil then
      if session.data.id_token ~= nil then
        -- Destroy the current session if it exists and just expired
        session:destroy()
      elseif err then
        -- Close the current session before returning an error message
        session:close()
      end
    end
    if err then
      uncached_response(
              ngx.HTTP_INTERNAL_SERVER_ERROR,
              "application/json",
              cjson.encode({message=err, tag="no bearer, authenticate", user_role=nil}))
      goto script_end
    end
  end

  -- If authenticate hasn't rejected us above but it's "open", i.e.
  -- non-authenticated users can see the page, clear X-User and
  -- X-User-Role by setting the value to nil.
  if res ~= nil then  -- Authentication worked
    -- Set user_id from response (either new, or from session data)
    user_id = res.id_token.sub

    -- This used to be cached in session, but for easier debugging this
    -- cache was removed. It was probably premature optimization; if
    -- requests are all slow then maybe it's time to add that back.

    -- Set user object for possible /api/auth/user response
    user = res.user

    -- Set Bearer header for nested requests
    --  - First tries to use session-derived access token; if it's unset,
    --    try using the response access token.
    -- TODO: Maybe only res token needed?
    local auth_token = res.access_token
    if auth_token == nil then
      auth_token, err = openidc.access_token()  -- TODO: Remove this block?
      if err ~= nil then ngx.log(ngx.ERR, err) end
    end
    if auth_token ~= nil then
      -- Set Authorization header to the access token for any (immediate)
      -- nested authorized requests to be made.
      nested_auth_header = "Bearer " .. auth_token
    end
  elseif session ~= nil then
    -- Close the session, since we don't need it anymore
    session:close()
  end
end

-- If an unrecoverable error occurred, it will jump here to skip everything and
-- avoid trying to execute code while in an invalid state.
::script_end::
