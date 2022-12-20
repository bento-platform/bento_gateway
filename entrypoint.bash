#!/bin/bash

# WORKDIR: /gateway

# Gather a list of all environment variables to use for the NGINX conf. template:
touch ./VARIABLES
echo "[bento_gateway] [entrypoint] gathering environment variables for configuration templates"
for v in $(env | awk -F "=" '{print $1}' | grep "BENTO*"); do
  echo "\${${v}}" >> ./VARIABLES
done
for v in $(env | awk -F "=" '{print $1}' | grep "CHORD*"); do
  echo "\${${v}}" >> ./VARIABLES
done

# Process the main NGINX conf. template, using only the selected variables:
#  - this avoids the ${DOLLAR}-type hack needed before
echo "[bento_gateway] [entrypoint] writing main NGINX configuration"
envsubst "$(cat ./VARIABLES)" \
  < ./conf/nginx.conf.tpl \
  > /usr/local/openresty/nginx/conf/nginx.conf

# Process any service templates, using only the selected variables:
echo "[bento_gateway] [entrypoint] writing service NGINX configuration"
for f in $(ls /usr/local/openresty/nginx/conf/bento_services/*.conf.tpl); do
  outfile="${f%%.*}.conf"
  echo "[bento_gateway] [entrypoint]    writing ${outfile}"
  envsubst "$(cat ./VARIABLES)" < "${f}" > "${outfile}"
done

# Start OpenResty
echo "[bento_gateway] [entrypoint] starting OpenResty"
/usr/bin/openresty -g 'daemon off;'
