FROM openresty/openresty:1.21.4.1-0-bullseye

WORKDIR /gateway
COPY conf conf
COPY src src
COPY entrypoint.bash entrypoint.bash

ENTRYPOINT ["bash", "./entrypoint.bash"]
