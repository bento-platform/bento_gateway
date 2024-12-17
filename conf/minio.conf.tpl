upstream minio {
    server ${BENTO_MINIO_CONTAINER_NAME}:${BENTO_MINIO_INTERNAL_PORT};
}

upstream minio_console {
    server ${BENTO_MINIO_CONTAINER_NAME}:${BENTO_MINIO_CONSOLE_PORT};
}

server {
    # tpl__tls_yes__start
    # Use 444 for internal SSL to allow streaming back to self (above)
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
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 300;
        # Default is HTTP/1, keepalive is only enabled in HTTP/1.1
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        chunked_transfer_encoding off;

        proxy_pass http://minio;
    }

    location /minio/ui/ {
        rewrite ^/minio/ui/(.*) /$1 break;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-NginX-Proxy true;

        # This is necessary to pass the correct IP to be hashed
        real_ip_header X-Real-IP;

        proxy_connect_timeout 300;

        # To support websockets in MinIO versions released after January 2023
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        # Some environments may encounter CORS errors (Kubernetes + Nginx Ingress)
        # Uncomment the following line to set the Origin request to an empty string
        # proxy_set_header Origin '';

        chunked_transfer_encoding off;

        proxy_pass http://minio_console; # This uses the upstream directive definition to load balance
   }
}
