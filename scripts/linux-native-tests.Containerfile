FROM alpine:3.24.3
RUN apk add --no-cache build-base linux-headers xz ripgrep fd python3
COPY zig.tar.xz /tmp/zig.tar.xz
RUN mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
