#!/bin/bash

echo "[bento_gateway] [entrypoint] ========== begin gateway entrypoint =========="

export BENTO_GATEWAY_CONF_DIR='/usr/local/openresty/nginx/conf'

# WORKDIR: /gateway

# Utility function - historically there's been some inconsistency in what value we use for "true"
# for feature flags / some other environment variables.
# This function ensures that all of those values get cast to '1', so only one value needs to be checked.
function true_values_to_1 () {
  if [[ "$1" == 1 || "$1" == "true" || "$1" == "True" || "$1" == "yes" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

# Utility function - process service templates into finalized NGINX configs
function service_templates_to_confs () {
  # $1 = "services" or "public_services"
  for f in $(ls /gateway/$1/*.conf.tpl); do
    filename=$(basename -- "$f")
    outfile="${filename%%.*}.conf"
    enable_check="$(python /gateway/src/service_conf_check.py < $f | tr -d '\n')"
    echo "[bento_gateway] [entrypoint]    ${filename}: enable_check=${enable_check}"
    if [[ "${enable_check}" == "true" ]]; then
      echo "[bento_gateway] [entrypoint]    writing ${outfile}"
      envsubst "$(cat ./VARIABLES)" \
        < "${f}" \
        > "${BENTO_GATEWAY_CONF_DIR}/bento_${1}/${outfile}"
    else
      echo "[bento_gateway] [entrypoint]    not enabling ${filename}"
    fi
  done
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
for v in $(env | awk -F "=" '{print $1}' | grep "GATEWAY*"); do
  echo "\${${v}}" >> ./VARIABLES
done

# Process the NGINX configuration templates, using only the selected variables:  ---------------------------------------

echo "[bento_gateway] [entrypoint] writing NGINX configuration files"

echo "[bento_gateway] [entrypoint] creating cbioportal.conf.pre"
envsubst "$(cat ./VARIABLES)" \
  < ./conf/cbioportal.conf.tpl \
  > ./cbioportal.conf.pre

CORS_PATH="${BENTO_GATEWAY_CONF_DIR}/cors.conf"
echo "[bento_gateway] [entrypoint] creating ${CORS_PATH}"
envsubst "$(cat ./VARIABLES)" \
  < ./conf/cors.conf.tpl \
  > "${CORS_PATH}"

echo "[bento_gateway] [entrypoint] creating redirect.conf.pre"
envsubst "$(cat ./VARIABLE)" \
  < ./conf/redirect.conf.tpl \
  > ./redirect.conf.pre

echo "[bento_gateway] [entrypoint] creating nginx.conf.pre"
envsubst "$(cat ./VARIABLES)" \
  < ./conf/nginx.conf.tpl \
  > ./nginx.conf.pre

# ----------------------------------------------------------------------------------------------------------------------

# Run "fine-tuning", i.e., processing the configuration files to *remove* chunks that aren't relevant to the environment
# variable settings for this instance. ---------------------------------------------------------------------------------

use_tls="$(true_values_to_1 $BENTO_GATEWAY_USE_TLS)"

# Run fine-tuning on cbioportal.conf.pre
if [[ "${use_tls}" == 0 ]]; then
  echo "[bento_gateway] [entrypoint] Fine-tuning cbioportal.conf to not use TLS"
  sed -i.bak \
      '/tpl__tls_yes__start/,/tpl__tls_yes__end/d' \
      ./cbioportal.conf.pre
else
  echo "[bento_gateway] [entrypoint] Fine-tuning cbioportal.conf to use TLS"
  sed -i.bak \
      '/tpl__tls_no__start/,/tpl__tls_no__end/d' \
      ./cbioportal.conf.pre
fi

# Run fine-tuning on redirect.conf.pre
if [[ "${use_tls}" == 0 ]]; then
  echo "[bento_gateway] [entrypoint] Fine-tuning redirect.conf to not use TLS"
  sed -i.bak \
      '/tpl__tls_yes__start/,/tpl__tls_yes__end/d' \
      ./redirect.conf.pre
else
  echo "[bento_gateway] [entrypoint] Fine-tuning redirect.conf to use TLS"
  sed -i.bak \
      '/tpl__tls_no__start/,/tpl__tls_no__end/d' \
      ./redirect.conf.pre
fi

# Run fine-tuning on nginx.conf.pre
if [[ "${use_tls}" == 0 ]]; then
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to not use TLS"
  sed -i.bak \
      '/tpl__tls_yes__start/,/tpl__tls_yes__end/d' \
      ./nginx.conf.pre
else
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to use TLS"
  sed -i.bak \
      '/tpl__tls_no__start/,/tpl__tls_no__end/d' \
      ./nginx.conf.pre
fi
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

if [[ "$(true_values_to_1 $BENTO_USE_DOMAIN_REDIRECT)" == 1 ]]; then
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to use domain redirect"
else
  echo "[bento_gateway] [entrypoint] Fine-tuning nginx.conf to disable domain redirect"
  sed -i.bak \
      '/tpl__redirect_yes__start/,/tpl__redirect_yes__end/d' \
      ./nginx.conf.pre
fi
# ----------------------------------------------------------------------------------------------------------------------

# Generate final configuration files / locations -----------------------------------------------------------------------
#  - Move cbioportal.conf into position
cp ./cbioportal.conf.pre "${BENTO_GATEWAY_CONF_DIR}/cbioportal.conf"
#  - Move redirect.conf into position
cp ./redirect.conf.pre "${BENTO_GATEWAY_CONF_DIR}/redirect.conf"
#  - Move nginx.conf into position
cp ./nginx.conf.pre "${BENTO_GATEWAY_CONF_DIR}/nginx.conf"
#  - Remove pre-final configuration files + any backups
rm ./*.conf.pre*
# ----------------------------------------------------------------------------------------------------------------------

cat "${BENTO_GATEWAY_CONF_DIR}/nginx.conf"

# Process any public service templates, using only the selected variables:
echo "[bento_gateway] [entrypoint] writing public service NGINX configuration"
service_templates_to_confs "public_services"

# Process any private service templates, using only the selected variables:
echo "[bento_gateway] [entrypoint] writing private service NGINX configuration"
service_templates_to_confs "services"

# Start OpenResty
echo "[bento_gateway] [entrypoint] starting OpenResty"
/usr/local/openresty/bin/openresty -g 'daemon off;'
