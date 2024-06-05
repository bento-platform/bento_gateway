worker_processes 2;
pcre_jit on;

# expose env vars to lua code
env BENTO_DEBUG;
env BENTO_AUTHZ_SERVICE_URL;

error_log stderr info;
load_module "modules/ngx_http_geoip_module.so";



events {
    worker_connections 2048;
    use epoll;  # Should be default on Linux, but explicitly use it
}

# tpl__tls_yes__start
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
    map_hash_max_size 128;
    map_hash_bucket_size 128;
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
# tpl__tls_yes__end

http {

    geoip_country /gateway/conf/GeoIP.dat;
    geoip_city /gateway/conf/GeoIPCity.dat;

    # setup alternative log format
    log_format json_analytics escape=json '{'
                            '"msec": "$msec", ' # request unixtime in seconds with a milliseconds resolution
                            '"connection": "$connection", ' # connection serial number
                            '"connection_requests": "$connection_requests", ' # number of requests made in connection
                    '"pid": "$pid", ' # process pid
                    '"request_id": "$request_id", ' # the unique request id
                    '"request_length": "$request_length", ' # request length (including headers and body)
                    '"remote_addr": "$remote_addr", ' # client IP
                    '"remote_user": "$remote_user", ' # client HTTP username
                    '"remote_port": "$remote_port", ' # client port
                    '"time_local": "$time_local", '
                    '"time_iso8601": "$time_iso8601", ' # local time in the ISO 8601 standard format
                    '"request": "$request", ' # full path no arguments if the request
                    '"request_uri": "$request_uri", ' # full path and arguments if the request
                    '"args": "$args", ' # args
                    '"status": "$status", ' # response status code
                    '"body_bytes_sent": "$body_bytes_sent", ' # the number of body bytes exclude headers sent to a client
                    '"bytes_sent": "$bytes_sent", ' # the number of bytes sent to a client
                    '"http_referer": "$http_referer", ' # HTTP referer
                    '"http_user_agent": "$http_user_agent", ' # user agent
                    '"http_x_forwarded_for": "$http_x_forwarded_for", ' # http_x_forwarded_for
                    '"http_host": "$http_host", ' # the request Host: header
                    '"server_name": "$server_name", ' # the name of the vhost serving the request
                    '"request_time": "$request_time", ' # request processing time in seconds with msec resolution
                    '"upstream": "$upstream_addr", ' # upstream backend server for proxied requests
                    '"upstream_connect_time": "$upstream_connect_time", ' # upstream handshake time incl. TLS
                    '"upstream_header_time": "$upstream_header_time", ' # time spent receiving upstream headers
                    '"upstream_response_time": "$upstream_response_time", ' # time spend receiving upstream body
                    '"upstream_response_length": "$upstream_response_length", ' # upstream response length
                    '"upstream_cache_status": "$upstream_cache_status", ' # cache HIT/MISS where applicable
                    '"ssl_protocol": "$ssl_protocol", ' # TLS protocol
                    '"ssl_cipher": "$ssl_cipher", ' # TLS cipher
                    '"scheme": "$scheme", ' # http or https
                    '"request_method": "$request_method", ' # request method
                    '"server_protocol": "$server_protocol", ' # request protocol, like HTTP/1.1 or HTTP/2.0
                    '"pipe": "$pipe", ' # "p" if request was pipelined, "." otherwise
                    '"gzip_ratio": "$gzip_ratio", '
                    '"http_cf_ray": "$http_cf_ray",'
                    '"geoip_country_code": "$geoip_country_code"'
                    '}';
    

    # Use the Docker embedded DNS server
    resolver 127.0.0.11 ipv6=off;

    # Allow SNI-based proxying
    proxy_ssl_server_name on;

    # Allow sendfile() for sending small files directly
    sendfile on;

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
    map_hash_max_size 128;
    map_hash_bucket_size 128;
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # tpl__tls_yes__start

    # Configure Lua HTTPS verification
    lua_ssl_verify_depth        2;
    lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;

    # Redirect all http to https
    server {
        access_log /var/log/access.log json_analytics;
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

    # tpl__tls_yes__end

    # tpl__tls_no__start
    # tpl__internal_idp__start
    # Keycloak for no-TLS setups; in this case, the TLS connection is terminated before traffic gets to the gateway, so
    # we have to proxy_pass here instead of streaming traffic above.
    server {
        access_log /var/log/access.log json_analytics;
        listen      80;
        server_name ${BENTOV2_AUTH_DOMAIN};

        location / {
            # Reverse proxy settings
            include     /gateway/conf/proxy.conf;
            include     /gateway/conf/proxy_large_headers.conf;

            # Immediate set/re-use means we don't get resolve errors if not up (as opposed to passing as a literal)
            set         $upstream_auth http://${BENTOV2_AUTH_CONTAINER_NAME}:${BENTOV2_AUTH_INTERNAL_PORT_PLAIN_HTTP};
            proxy_pass  $upstream_auth;

            error_log   /var/log/bentov2_auth_errors.log;
        }
    }
    # tpl__internal_idp__end
    # tpl__tls_no__end

    # Bento Public
    map $http_origin $public_cors {
        default                          '';
        https://${BENTOV2_DOMAIN}        https://${BENTOV2_DOMAIN};
        https://${BENTOV2_PORTAL_DOMAIN} https://${BENTOV2_PORTAL_DOMAIN};
    }
    server {
        access_log /var/log/access.log json_analytics;
        # tpl__tls_yes__start
        # Use 444 for internal SSL to allow streaming back to self (above)
        listen 444 ssl;
        # tpl__tls_yes__end

        # tpl__tls_no__start
        # Use 81 for internal HTTP to allow streaming back to self (above)
        listen 80;
        # tpl__tls_no__end

        server_name ${BENTOV2_DOMAIN};

        # tpl__tls_yes__start
        ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_FULLCHAIN_RELATIVE_PATH};
        ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PRIVKEY_RELATIVE_PATH};
        # tpl__tls_yes__end

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
        # tpl__use_bento_public__end

        # Include all public service location blocks (mounted into the container)
        include bento_public_services/*.conf;

        # tpl__do_not_use_bento_public__start
        return 301 https://portal.$host$request_uri;
        # tpl__do_not_use_bento_public__end
    }


    # Bento Portal
    server {
        access_log /var/log/access.log json_analytics;
        # tpl__tls_yes__start
        # Use 444 for internal SSL to allow streaming back to self (above)
        listen 444 ssl;
        # tpl__tls_yes__end

        # tpl__tls_no__start
        listen 80;
        # tpl__tls_no__end

        server_name ${BENTOV2_PORTAL_DOMAIN};

        # tpl__tls_yes__start
        ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PORTAL_FULLCHAIN_RELATIVE_PATH};
        ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PORTAL_PRIVKEY_RELATIVE_PATH};
        # tpl__tls_yes__end

        # Security --
        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        # --

        # Web
        location / {
            # Reverse proxy settings
            include /gateway/conf/proxy.conf;

            set $request_url $request_uri;
            set $url $uri;

            # Immediate set/re-use means we don't get resolve errors if not up (as opposed to passing as a literal)
            set $upstream_web http://${BENTOV2_WEB_CONTAINER_NAME}:${BENTOV2_WEB_INTERNAL_PORT};

            proxy_pass $upstream_web;
            error_log /var/log/bentov2_web_errors.log;
        }

        # --- All API stuff -- /api/* ---

        # -- Fallback 404 to avoid returning web HTML when an API request is made
        location /api/ {
            return 404;
        }

        # Include all service location blocks (mounted into the container)
        include bento_services/*.conf;
    }

    # tpl__use_cbioportal__start
    # cBioPortal
    include cbioportal.conf;
    # tpl__use_cbioportal__end

    # tpl__redirect_yes__start
    # Redirect requests from an old domain (BENTO_DOMAIN_REDIRECT) to the current one (BENTOV2_DOMAIN).
    server {
        access_log /var/log/access.log json_analytics;
        # tpl__tls_yes__start
        # Use 444 for internal SSL to allow streaming back to self (above)
        listen 444 ssl;
        # tpl__tls_yes__end

        # tpl__tls_no__start
        listen 80;
        # tpl__tls_no__end

        # tpl__tls_yes__start
        ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTO_GATEWAY_INTERNAL_REDIRECT_FULLCHAIN_RELATIVE_PATH};
        ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTO_GATEWAY_INTERNAL_REDIRECT_PRIVKEY_RELATIVE_PATH};
        # tpl__tls_yes__end

        # Redirect all trafic from the old domain and subdomains to BENTOV2_DOMAIN
        server_name *.${BENTO_DOMAIN_REDIRECT} ${BENTO_DOMAIN_REDIRECT};
        return 301 https://${BENTOV2_DOMAIN};
    }
    # tpl__redirect_yes__end

}
