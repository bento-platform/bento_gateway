FROM openresty/openresty:1.21.4.1-0-alpine-fat

# Install apt and lua dependencies
RUN apk update && \
    apk add git bash && \
    /usr/local/openresty/luajit/bin/luarocks install lua-resty-session lua-resty-openidc

WORKDIR /gateway
RUN mkdir -p /usr/local/openresty/nginx/conf/bento_services && \
    mkdir -p /gateway/services
COPY LICENSE LICENSE
COPY conf conf
COPY src src
COPY entrypoint.bash entrypoint.bash

ENTRYPOINT ["bash", "./entrypoint.bash"]
