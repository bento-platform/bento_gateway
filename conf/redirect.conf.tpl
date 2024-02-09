server {
    # tpl__tls_yes__start
    # Use 444 for internal SSL to allow streaming back to self (above)
    listen 444 ssl;
    # tpl__tls_yes__end

    # tpl__tls_no__start
    # Use 81 for internal HTTP to allow streaming back to self (above)
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
