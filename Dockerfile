# Rust dedicated server image for Pterodactyl.
# Based on the official pterodactyl/yolks games/rust image (MIT), extended with
# beta branch support, Oxide/Carbon handling and extension downloads.

FROM        --platform=linux/amd64 node:20-bookworm-slim

LABEL       org.opencontainers.image.title="Paradox Rust"
LABEL       org.opencontainers.image.description="Rust dedicated server for Pterodactyl with branch, Oxide/Carbon and extension support"
LABEL       org.opencontainers.image.source="https://github.com/ParadoxLabs-LLC/RustEgg"
LABEL       org.opencontainers.image.licenses=MIT

ENV         DEBIAN_FRONTEND=noninteractive

RUN         dpkg --add-architecture i386 \
            && apt-get update \
            && apt-get upgrade -y \
            && apt-get install -y --no-install-recommends \
                ca-certificates curl unzip tar gzip iproute2 tzdata procps \
                lib32gcc-s1 lib32stdc++6 libgdiplus libsdl2-2.0-0:i386 \
            && rm -rf /var/lib/apt/lists/*

RUN         mkdir /node_modules \
            && npm install --prefix / ws@8 \
            && npm cache clean --force

RUN         useradd -d /home/container -m container

COPY        ./entrypoint.sh /entrypoint.sh
COPY        ./wrapper.js /wrapper.js

# Strip Windows line endings in case the files were edited on Windows.
RUN         sed -i 's/\r$//' /entrypoint.sh /wrapper.js && chmod 755 /entrypoint.sh

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

CMD         [ "/bin/bash", "/entrypoint.sh" ]
