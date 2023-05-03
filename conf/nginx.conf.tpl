worker_processes 1;

# expose env vars to lua code
env CHORD_DEBUG;
env CHORD_PERMISSIONS;
env CHORD_PRIVATE_MODE;
env CHORD_URL;

env OIDC_DISCOVERY_URI;
env REDIRECT_AFTER_LOGOUT_URI;
env CLIENT_ID;
env TOKEN_ENDPOINT_AUTH_METHOD;

# TODO: move to secret instead of using env
env CLIENT_SECRET;

env CBIOPORTAL_URL;

error_log stderr info;

events {
    worker_connections 1024;
}

# Pass through SSL connection to either Keycloak or the Bento gateway.
# - Don't change the # -- ... -- lines, as they are used to find/replace chunks.
# - Can't add security headers on stream blocks - rely on Keycloak's own security settings.
stream {
    # Use the Docker embedded DNS server
    resolver 127.0.0.11 ipv6=off;

    # Allow SNI-based proxying
    proxy_ssl_server_name on;

    # server_name doesn't exist in stream blocks
    # instead, use SSL preread to redirect either back to the gateway or to the auth container,
    # since we want to terminate SSL at Keycloak, not at the gateway.
    map $ssl_preread_server_name $name {
        # tpl__internal_idp__start
        ${BENTOV2_AUTH_DOMAIN}  ${BENTOV2_AUTH_CONTAINER_NAME}:${BENTOV2_AUTH_INTERNAL_PORT};
        # tpl__internal_idp__end
        default                 ${BENTOV2_GATEWAY_CONTAINER_NAME}:444;
    }

    server {
        listen      443;
        error_log   /var/log/bentov2_auth_errors.log;
        ssl_preread on;
        proxy_pass  $name;
    }
}

http {
    # Use the Docker embedded DNS server
    resolver 127.0.0.11 ipv6=off;

    # Set up log format
    log_format compression '$remote_addr - $remote_user [$time_local] '
                           '"$request" $status $body_bytes_sent '
                           '"$http_referer" "$http_user_agent" "$gzip_ratio" "$uri"';

    # Set up per-server and per-address rate limiter
    limit_req_zone $binary_remote_addr zone=perip:10m rate=10r/s;
    limit_req_zone $server_name zone=perserver:10m rate=40r/s;

    # Beacon-specific rate limiting zone; much more aggressive
    limit_req_zone $binary_remote_addr zone=beacon_perip:10m rate=1r/s;

    # Explicitly prevent underscores in headers from being passed, even though
    # off is the default. This prevents auth header forging.
    # e.g. https://docs.djangoproject.com/en/3.0/howto/auth-remote-user/
    underscores_in_headers off;

    # Prevent proxy from trying multiple upstreams.
    proxy_next_upstream off;

    # From http://nginx.org/en/docs/http/websocket.html
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }


    # Redirect all http to https
    server {
        listen 80 default_server;
        listen [::]:80 default_server;

        server_name _; # Redirect http no matter the domain name

        # Security --
        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        # --

        return 301 https://$host$request_uri;
    }


    # No unspecified domain funnies allowed!
    server {
        listen 444 ssl;
        ssl_reject_handshake on;
    }


    # Bento Public
    server {
        # Use 444 for internal SSL to allow streaming back to self (above)
        listen 444 ssl;

        server_name ${BENTOV2_DOMAIN};

        ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_FULLCHAIN_RELATIVE_PATH};
        ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PRIVKEY_RELATIVE_PATH};

        # Security --
        add_header Content-Security-Policy "frame-src 'self' ${BENTOV2_GATEWAY_PUBLIC_ALLOW_FRAME_DOMAINS};";
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        # --

        # tpl__use_bento_public__start
        # Public Web
        location / {
            # Reverse proxy settings
            include /gateway/conf/proxy.conf;

            # Immediate set/re-use means we don't get resolve errors if not up (as opposed to passing as a literal)
            set         $upstream_public http://${BENTO_PUBLIC_CONTAINER_NAME}:${BENTO_PUBLIC_INTERNAL_PORT};
            proxy_pass  $upstream_public;

            error_log /var/log/bentov2_public_errors.log;
        }

        # -- Beacon
        #  - Beacon is in the "Bento Public" namespace, since it yields public data.
        location ~ /api/beacon {
            # Reverse proxy settings
            include /gateway/conf/rate_limit_beacon.conf;  # More aggressive than the proxy.conf ones
            include /gateway/conf/proxy.conf;
            include /gateway/conf/proxy_extra.conf;

            # Remove "/api/beacon" from the path
            rewrite /api/beacon/(.*) /$1  break;

            # Forward request to beacon
            proxy_pass http://${BENTO_BEACON_CONTAINER_NAME}:${BENTO_BEACON_INTERNAL_PORT}/$1$is_args$args;

            # Errors
            error_log /var/log/bentov2_beacon_errors.log;
        }

        # tpl__use_bento_public__end
        # tpl__do_not_use_bento_public__start
        return 301 https://portal.$host$request_uri;
        # tpl__do_not_use_bento_public__end
    }


    # Bento Portal
    server {
        # Use 444 for internal SSL to allow streaming back to self (above)
        listen 444 ssl;

        server_name ${BENTOV2_PORTAL_DOMAIN};

        ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PORTAL_FULLCHAIN_RELATIVE_PATH};
        ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PORTAL_PRIVKEY_RELATIVE_PATH};

        # Security --
        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        # --


        # CHORD constants (configuration file locations)
        set $chord_auth_config     "{auth_config}";
        set $chord_instance_config "{instance_config}";

        # lua-resty-session configuration
        #  - This is important! It configures exactly how we want our sessions to function,
        #    and allows us to share session data across multiple workers.
        set $session_cipher           none;   # SECURITY: only use this with Redis; don't need to encrypt session ID
        set $session_cookie_samesite  None;  # Needs to be none(?), otherwise our session cookie gets weird
        set $session_storage          redis;
        set $session_redis_prefix     oidc;
        set $session_redis_host       ${BENTOV2_REDIS_CONTAINER_NAME};
        set $session_secret           ${BENTOV2_SESSION_SECRET};

        # - Per lua-resty-session, the 'regenerate' strategy is more reliable for
        #   SPAs which make a lot of asynchronous requests, as it does not
        #   immediately replace the old records for sessions when making a new one.
        # - We don't need locking with regenerate session strat: https://github.com/bungle/lua-resty-session/issues/113
        #   This can help performance if we forget to release a lock / close a session somewhere.
        set $session_redis_uselocking  no;
        set $session_strategy          regenerate;


        # Web
        location / {
            # Reverse proxy settings
            include /gateway/conf/proxy.conf;
            include /gateway/conf/proxy_private.conf;

            set $request_url $request_uri;
            set $url $uri;

            # Immediate set/re-use means we don't get resolve errors if not up (as opposed to passing as a literal)
            set $upstream_web http://${BENTOV2_WEB_CONTAINER_NAME}:${BENTOV2_WEB_INTERNAL_PORT};

            proxy_pass $upstream_web;
            error_log /var/log/bentov2_web_errors.log;
        }

        # --- All API stuff -- /api/* ---
        # -- Public node-info
        location = /api/node-info {
            limit_req zone=perip burst=10 nodelay;
            limit_req zone=perserver burst=30;
            content_by_lua_file /gateway/src/node_info.lua;
        }

        # -- User Auth
        location ~ /api/auth {
            limit_req zone=perip burst=10 nodelay;
            limit_req zone=perserver burst=30;
            set_by_lua_block $original_uri { return ngx.var.uri }
            content_by_lua_file /gateway/src/proxy_auth.lua;
        }

        # Include all service location blocks (mounted into the container)
        # Don't include template files (.conf.tpl), just processed .conf files
        include bento_services/*.conf;
    }


    # tpl__use_cbioportal__start
    # cBioPortal
    server {
        # Use 444 for internal SSL to allow streaming back to self (above)
        listen 444 ssl;

        server_name ${BENTOV2_CBIOPORTAL_DOMAIN};

        ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_CBIOPORTAL_FULLCHAIN_RELATIVE_PATH};
        ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_CBIOPORTAL_PRIVKEY_RELATIVE_PATH};

        # Frame embedding: allow private portal to embed cBioPortal as an iframe:
        add_header Content-Security-Policy "frame-ancestors 'self' https://${BENTOV2_PORTAL_DOMAIN};";

        # CHORD constants (configuration file locations)
        set $chord_auth_config     "{auth_config}";
        set $chord_instance_config "{instance_config}";

        # lua-resty-session configuration
        #  - This is important! It configures exactly how we want our sessions to function,
        #    and allows us to share session data across multiple workers.
        set $session_cipher           none;   # SECURITY: only use this with Redis; don't need to encrypt session ID
        set $session_cookie_samesite  None;  # Needs to be none(?), otherwise our session cookie gets weird
        set $session_storage          redis;
        set $session_redis_prefix     oidc;
        set $session_redis_host       ${BENTOV2_REDIS_CONTAINER_NAME};
        set $session_secret           ${BENTOV2_SESSION_SECRET};

        # - Per lua-resty-session, the 'regenerate' strategy is more reliable for
        #   SPAs which make a lot of asynchronous requests, as it does not
        #   immediately replace the old records for sessions when making a new one.
        # - We don't need locking with regenerate session strat: https://github.com/bungle/lua-resty-session/issues/113
        #   This can help performance if we forget to release a lock / close a session somewhere.
        set $session_redis_uselocking  no;
        set $session_strategy          regenerate;

        # Proxy pass to cBioPortal container
        location / {
            # Reverse proxy settings
            include /gateway/conf/proxy.conf;
            include /gateway/conf/proxy_cbioportal.conf;

            set $request_url $request_uri;
            set $url $uri;

            # Immediate set/re-use means we don't get resolve errors if not up (as opposed to passing as a literal)
            set $upstream_cbio http://${BENTO_CBIOPORTAL_CONTAINER_NAME}:${BENTO_CBIOPORTAL_INTERNAL_PORT};

            proxy_pass $upstream_cbio;
            error_log /var/log/bentov2_cbio_errors.log;
        }
    }
    # tpl__use_cbioportal__end
}
