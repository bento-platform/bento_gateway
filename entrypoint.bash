#!/bin/bash

# Gather a list of all environment variables to use for the NGINX conf. template:
touch ./VARIABLES
echo "[bento_gateway] [entrypoint] gathering environment variables for configuration templates"
for v in $(env | awk -F "=" '{print $1}' | grep "BENTO*"); do
  echo "\${${v}}" >> ./VARIABLES
done
for v in $(env | awk -F "=" '{print $1}' | grep "CHORD*"); do
  echo "\${${v}}" >> ./VARIABLES
done

# Process the NGINX conf. template, using only the selected variables:
#  - this avoids the ${DOLLAR}-type hack needed before
echo "[bento_gateway] [entrypoint] writing NGINX configuration"
envsubst "$(cat ./VARIABLES)" \
  < ./conf/nginx.conf.tpl \
  > /usr/local/openresty/nginx/conf/nginx.conf

# Start OpenResty
echo "[bento_gateway] [entrypoint] starting OpenResty"
/usr/bin/openresty -g 'daemon off;'
