upstream garage_s3 {
    server ${BENTO_GARAGE_CONTAINER_NAME}:${BENTO_GARAGE_S3_API_PORT};
}

upstream garage_web {
    server ${BENTO_GARAGE_CONTAINER_NAME}:${BENTO_GARAGE_WEB_PORT};
}

# Main S3 API endpoint (path-style and virtual-hosted-style buckets)
server {
    # tpl__tls_yes__start
    listen 444 ssl;
    # tpl__tls_yes__end

    # tpl__tls_no__start
    listen 80;
    # tpl__tls_no__end

    server_name ${BENTO_GARAGE_DOMAIN} *.s3.${BENTO_GARAGE_DOMAIN};

    # tpl__tls_yes__start
    ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_FULLCHAIN_RELATIVE_PATH};
    ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PRIVKEY_RELATIVE_PATH};
    # tpl__tls_yes__end

    # Allow special characters in headers
    ignore_invalid_headers off;

    # Allow any size file to be uploaded.
    # Set to a value such as 1000m; to restrict file size to a specific value
    client_max_body_size 0;

    # Disable buffering
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        # Reverse proxy settings
        include /gateway/conf/proxy.conf;
        include /gateway/conf/proxy_timeouts.conf;
        proxy_connect_timeout 300;
        # Default is HTTP/1, keepalive is only enabled in HTTP/1.1
        proxy_set_header Connection "";
        chunked_transfer_encoding off;

        proxy_pass http://garage_s3;
        proxy_set_header Host $host;

        # Errors
        error_log /var/log/bentov2_garage_errors.log;
    }
}

# Web interface for static website hosting
server {
    # tpl__tls_yes__start
    listen 444 ssl;
    # tpl__tls_yes__end

    # tpl__tls_no__start
    listen 80;
    # tpl__tls_no__end

    server_name *.web.${BENTO_GARAGE_DOMAIN};

    # tpl__tls_yes__start
    ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_FULLCHAIN_RELATIVE_PATH};
    ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PRIVKEY_RELATIVE_PATH};
    # tpl__tls_yes__end

    # Allow any size file
    client_max_body_size 0;

    # Disable buffering
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        # Reverse proxy settings
        include /gateway/conf/proxy.conf;
        include /gateway/conf/proxy_timeouts.conf;
        proxy_connect_timeout 300;
        proxy_set_header Connection "";
        chunked_transfer_encoding off;

        proxy_pass http://garage_web;
        proxy_set_header Host $host;

        # Errors
        error_log /var/log/bentov2_garage_errors.log;
    }
}
