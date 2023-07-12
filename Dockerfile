FROM openresty/openresty:1.21.4.1-8-alpine-fat

# Install apt and lua dependencies
RUN apk add --no-cache git bash python3 && \
    /usr/local/openresty/luajit/bin/luarocks install lua-resty-session && \
    /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

WORKDIR /gateway
RUN mkdir -p /usr/local/openresty/nginx/conf/bento_services && \
    mkdir -p /usr/local/openresty/nginx/conf/bento_public_services && \
    mkdir -p /gateway/services && \
    mkdir -p /gateway/public_services
COPY LICENSE LICENSE
COPY conf conf
COPY src src
COPY entrypoint.bash entrypoint.bash

ENTRYPOINT ["bash", "./entrypoint.bash"]
