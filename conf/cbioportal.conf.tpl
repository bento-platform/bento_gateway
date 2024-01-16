server {
    # tpl__tls_yes__start
    # Use 444 for internal SSL to allow streaming back to self (above)
    listen 444 ssl;
    # tpl__tls_yes__end

    # tpl__tls_no__start
    listen 80;
    # tpl__tls_no__end

    server_name ${BENTOV2_CBIOPORTAL_DOMAIN};

    ssl_certificate ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_CBIOPORTAL_FULLCHAIN_RELATIVE_PATH};
    ssl_certificate_key ${BENTOV2_GATEWAY_INTERNAL_CERTS_DIR}${BENTOV2_GATEWAY_INTERNAL_CBIOPORTAL_PRIVKEY_RELATIVE_PATH};

    # Frame embedding: allow private portal to embed cBioPortal as an iframe:
    add_header Content-Security-Policy "frame-ancestors 'self' https://${BENTOV2_PORTAL_DOMAIN};";

    # Proxy pass to cBioPortal container
    location / {
        # Reverse proxy settings
        include /gateway/conf/proxy.conf;
        include /gateway/conf/proxy_cbioportal.conf;

        # Immediate set/re-use means we don't get resolve errors if not up (as opposed to passing as a literal)
        set $upstream_cbio http://${BENTO_CBIOPORTAL_CONTAINER_NAME}:${BENTO_CBIOPORTAL_INTERNAL_PORT};

        proxy_pass $upstream_cbio;
        error_log /var/log/bentov2_cbio_errors.log;
    }
}
