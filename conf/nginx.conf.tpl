worker_processes 2;

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

error_log stderr info;

events {
    worker_connections 1024;
}
# -- Internal IDP Starts Here --
# BentoV2 Auth - Pass through SSL connection
# -
stream {
    # Use the Docker embedded DNS server
    resolver 127.0.0.11 ipv6=off;

    # server_name doesn't exist in stream blocks
    # instead, use SSL preread to redirect either back to the gateway
    map $ssl_preread_server_name $name {
        ${BENTOV2_AUTH_DOMAIN}  auth_server;
        default                 bento_gateway;
    }

    upstream auth_server {
        server ${BENTOV2_AUTH_CONTAINER_NAME}:${BENTOV2_AUTH_INTERNAL_PORT};
    }
    upstream bento_gateway {
        server ${BENTOV2_GATEWAY_CONTAINER_NAME}:444;
    }

    server {
        listen 443;

        # Security --
#         add_header  X-Frame-Options "SAMEORIGIN";
#         add_header  X-XSS-Protection "1; mode=block";
#         add_header  Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        # --

        error_log   /var/log/bentov2_auth_errors.log info;

        ssl_preread on;
        proxy_pass  $name;
    }
}
# -- Internal IDP Ends Here --

http {
    # Use the Docker embedded DNS server
    resolver 127.0.0.11 ipv6=off;

    log_format compression '$remote_addr - $remote_user [$time_local] '
                           '"$request" $status $body_bytes_sent '
                           '"$http_referer" "$http_user_agent" "$gzip_ratio" "$uri"';

    limit_req_zone $binary_remote_addr zone=perip:10m rate=10r/s;
    limit_req_zone $server_name zone=perserver:10m rate=30r/s;

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

        # -- Use Bento-Public Starts Here --
        # Public Web
        location / {
            # Reverse proxy settings
            include /gateway/conf/proxy.conf;

            set $upstream_public http://${BENTO_PUBLIC_CONTAINER_NAME}:${BENTO_PUBLIC_INTERNAL_PORT};
            proxy_pass    $upstream_public;

            error_log /var/log/bentov2_public_errors.log;
        }

        # -- Beacon
        #  - Beacon is in the "Bento Public" namespace, since it yields public data.
        location ~ /api/beacon {
            # Reverse proxy settings
            include /gateway/conf/proxy.conf;
            include /gateway/conf/proxy_extra.conf;

            # Remove "/api/beacon" from the path
            rewrite /api/beacon/(.*) /$1  break;

            # Forward request to beacon
            proxy_pass http://${BEACON_CONTAINER_NAME}:${BEACON_INTERNAL_PORT}/$1$is_args$args;

            # Errors
            error_log /var/log/bentov2_beacon_errors.log;
        }

        # -- Use Bento-Public Ends Here --
        # -- Do Not Use Bento-Public Starts Here --
        return 301 https://portal.$host$request_uri;
        # -- Do Not Use Bento-Public Ends Here --
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

        # - Per lua-resty-session, the 'regenerate' strategy is more reliable for
        #   SPAs which make a lot of asynchronous requests, as it does not
        #   immediately replace the old records for sessions when making a new one.
        set $session_strategy        regenerate;


        # Web
        location / {
            # Reverse proxy settings
            include /gateway/conf/proxy.conf;
            include /gateway/conf/proxy_private.conf;

            set $request_url $request_uri;
            set $url $uri;

            set $upstream_web http://${BENTOV2_WEB_CONTAINER_NAME}:${BENTOV2_WEB_INTERNAL_PORT};

            proxy_pass $upstream_web;
            error_log /var/log/bentov2_web_errors.log;
        }

        # --- All API stuff -- /api/* ---
        # -- Public node-info
        location = /api/node-info {
            limit_req zone=perip burst=30 nodelay;
            limit_req zone=perserver burst=90;
            content_by_lua_file /gateway/src/node_info.lua;
        }

        # -- User Auth
        location ~ /api/auth {
            limit_req zone=perip burst=30 nodelay;
            limit_req zone=perserver burst=90;
            set_by_lua_block $original_uri { return ngx.var.uri }
            content_by_lua_file /gateway/src/proxy_auth.lua;
        }

        # Include all service location blocks (mounted into the container)
        # Don't include template files (.conf.tpl), just processed .conf files
        include bento_services/*.conf;
    }
}
