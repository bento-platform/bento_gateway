server {
    # tpl__tls_yes__start
    listen 444 ssl;
    # tpl__tls_yes__end

    # tpl__tls_no__start
    listen 80;
    # tpl__tls_no__end

    server_name ${BENTO_MINIO_DOMAIN};

    # tpl__tls_yes__start
    ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTO_GATEWAY_INTERNAL_MINIO_FULLCHAIN_RELATIVE_PATH};
    ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTO_GATEWAY_INTERNAL_MINIO_PRIVKEY_RELATIVE_PATH};
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
        include /gateway/conf/proxy_extra.conf;
        proxy_connect_timeout 300;
        # Default is HTTP/1, keepalive is only enabled in HTTP/1.1
        proxy_set_header Connection "";
        chunked_transfer_encoding off;

        proxy_pass http://${BENTO_MINIO_CONTAINER_NAME}:${BENTO_MINIO_INTERNAL_PORT};

        # Errors
        error_log /var/log/bentov2_minio_errors.log;
    }

    location /minio/ui { return 302  https://${BENTOV2_DOMAIN}/minio/ui/; }
    location /minio/ui/ {
        # General reverse proxy settings
        include /gateway/conf/proxy.conf;
        include /gateway/conf/proxy_extra.conf;

        # This is necessary to pass the correct IP to be hashed
        proxy_set_header X-NginX-Proxy true;
        real_ip_header X-Real-IP;

        proxy_connect_timeout 300;

        # Some environments may encounter CORS errors (Kubernetes + Nginx Ingress)
        # Uncomment the following line to set the Origin request to an empty string
        proxy_set_header Origin '';

        chunked_transfer_encoding off;

        rewrite ^ $request_uri;
        rewrite ^/minio/ui/(.*) /$1 break;
        proxy_pass http://${BENTO_MINIO_CONTAINER_NAME}:${BENTO_MINIO_CONSOLE_PORT}$uri;

        # Add sub_filter directives to rewrite base href
        sub_filter '<base href="/"' '<base href="/minio/ui/"';
        sub_filter_once on;

        # Ensure sub_filter module is enabled
        proxy_set_header Accept-Encoding "";    

        # Errors
        error_log /var/log/bentov2_minio_errors.log;
   }
}
