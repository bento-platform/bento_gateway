#!/bin/bash

# WORKDIR: /gateway

function true_values_to_1 () {
  if [[ "$1" == 1 || "$1" == "true" || "$1" == "True" || "$1" == "yes" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

# Check required environment variables that may accidentally be unset (i.e., need to be set by hand)
if [[ -z "${BENTOV2_SESSION_SECRET}" ]]; then
  echo "[bento_gateway] [entrypoint] BENTOV2_SESSION_SECRET is not set. Exiting..." 1>&2
  exit 1
fi

# Gather a list of all environment variables to use for the NGINX conf. template:
touch ./VARIABLES
echo "[bento_gateway] [entrypoint] gathering environment variables for configuration templates"
for v in $(env | awk -F "=" '{print $1}' | grep "BENTO*"); do
  echo "\${${v}}" >> ./VARIABLES
done
for v in $(env | awk -F "=" '{print $1}' | grep "CHORD*"); do
  echo "\${${v}}" >> ./VARIABLES
done
for v in $(env | awk -F "=" '{print $1}' | grep "GATEWAY*"); do
  echo "\${${v}}" >> ./VARIABLES
done

# Process the main NGINX conf. template, using only the selected variables:
#  - this avoids the ${DOLLAR}-type hack needed before
echo "[bento_gateway] [entrypoint] writing main NGINX configuration"
envsubst "$(cat ./VARIABLES)" \
  < ./conf/nginx.conf.tpl \
  > ./nginx.conf.pre

# Run fine-tuning on nginx.conf.pre
if [[ "$(true_values_to_1 $BENTOV2_USE_EXTERNAL_IDP)" == 1 ]]; then
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to use an external IDP"
  sed -i.bak \
    '/tpl__internal_idp__start/,/tpl__internal_idp__end/d' \
    ./nginx.conf.pre
else
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to use an internal IDP"
fi
if [[ "$(true_values_to_1 $BENTOV2_USE_BENTO_PUBLIC)" == 1 ]]; then
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to use bento_public"
  sed -i.bak \
    '/tpl__do_not_use_bento_public__start/,/tpl__do_not_use_bento_public__end/d' \
    ./nginx.conf.pre
else
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to disable bento_public"
  sed -i.bak \
    '/tpl__use_bento_public__start/,/tpl__use_bento_public__end/d' \
    ./nginx.conf.pre
fi
if [[ "$(true_values_to_1 $BENTO_CBIOPORTAL_ENABLED)" == 1 ]]; then
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to use cBioPortal"
else
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to disable cBioPortal"
  sed -i.bak \
      '/tpl__use_cbioportal__start/,/tpl__use_cbioportal__end/d' \
      ./nginx.conf.pre
fi

# Move nginx.conf into position
cp ./nginx.conf.pre /usr/local/openresty/nginx/conf/nginx.conf
rm ./nginx.conf.pre*  # Remove pre-final file + any backups

cat /usr/local/openresty/nginx/conf/nginx.conf

# Process any service templates, using only the selected variables:
echo "[bento_gateway] [entrypoint] writing service NGINX configuration"
for f in $(ls /gateway/services/*.conf.tpl); do
  filename=$(basename -- "$f")
  outfile="${filename%%.*}.conf"
  echo "[bento_gateway] [entrypoint]    writing ${outfile}"
  envsubst "$(cat ./VARIABLES)" \
    < "${f}" \
    > "/usr/local/openresty/nginx/conf/bento_services/${outfile}"
done

# Start OpenResty
echo "[bento_gateway] [entrypoint] starting OpenResty"
/usr/local/openresty/bin/openresty -g 'daemon off;'
