add_header Content-Security-Policy "frame-src 'self' ${BENTOV2_GATEWAY_PUBLIC_ALLOW_FRAME_DOMAINS};";
add_header X-XSS-Protection "1; mode=block";
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

# if ($http_origin ~* "^https://(${BENTOV2_DOMAIN}|${BENTOV2_PORTAL_DOMAIN})$") {
    add_header 'Access-Control-Allow-Origin'      '$http_origin'  always;
    add_header 'Access-Control-Allow-Credentials' 'true'          always;
    add_header 'Access-Control-Allow-Headers'     'authorization' always;
# }
