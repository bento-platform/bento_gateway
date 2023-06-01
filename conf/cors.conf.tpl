if ($http_origin ~* "^https://(${BENTOV2_DOMAIN}|${BENTOV2_PORTAL_DOMAIN})$") {
    add_header 'Access-Control-Allow-Origin'      '$http_origin';
    add_header 'Access-Control-Allow-Credentials' 'true';
}
