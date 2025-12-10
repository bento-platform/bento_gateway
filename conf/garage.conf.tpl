# Main S3 API endpoint (path-style buckets)
server {
    # tpl__tls_yes__start
    listen 444 ssl;
    # tpl__tls_yes__end

    # tpl__tls_no__start
    listen 80;
    # tpl__tls_no__end

    server_name ${BENTO_GARAGE_DOMAIN};

    # tpl__tls_yes__start
    ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_FULLCHAIN_RELATIVE_PATH};
    ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_PRIVKEY_RELATIVE_PATH};
    # tpl__tls_yes__end

    ignore_invalid_headers off;
    client_max_body_size 0;

    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        include /gateway/conf/proxy.conf;
        include /gateway/conf/proxy_timeouts.conf;

        proxy_connect_timeout 300;
        proxy_set_header Connection "";
        chunked_transfer_encoding off;

        # Direct backend instead of upstream garage_s3
        proxy_pass http://${BENTO_GARAGE_CONTAINER_NAME}:${BENTO_GARAGE_S3_API_PORT};

        proxy_set_header Host $host;

        error_log /var/log/bentov2_garage_errors.log;
    }
}
