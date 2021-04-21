FROM debian:buster-slim AS base

FROM base AS downloader
# hadolint ignore=DL3009,DL3008
RUN apt-get update \
  && apt-get install --yes --no-install-recommends \
   ca-certificates \
   wget \
   gnupg \
   dirmngr \
   git \
   xz-utils

FROM downloader AS upx
RUN wget -nv --compression=gzip -O "upx-3.96-amd64_linux.tar.xz" "https://github.com/upx/upx/releases/download/v3.96/upx-3.96-amd64_linux.tar.xz" \
  && tar xf "upx-3.96-amd64_linux.tar.xz" --strip-components=1 \
  && chmod +x /upx

FROM downloader AS haproxy
ARG HAPROXY_VERSION=2.3.9
ARG HAPROXY_SHA256=77110bc1272bad18fff56b30f4614bcc1deb50600ae42cb0f0b161fc41e2ba96
RUN wget -nv --compression=gzip -O "haproxy-${HAPROXY_VERSION}.tar.gz" "https://www.haproxy.org/download/2.3/src/haproxy-${HAPROXY_VERSION}.tar.gz" \
  && echo "${HAPROXY_SHA256} *haproxy-${HAPROXY_VERSION}.tar.gz" | sha256sum -c \
  && mkdir -p /usr/src/haproxy \
  && tar xzf "haproxy-${HAPROXY_VERSION}.tar.gz" -C /usr/src/haproxy --strip-components=1

FROM base AS builder
ARG HAPROXY_VERSION=2.3.9
COPY --from=haproxy /usr/src/haproxy /usr/src/haproxy
WORKDIR /usr/src/haproxy
RUN apt-get update \
  && apt-get install --yes --no-install-recommends \
    make \
    gcc \
    libpcre3-dev \
    libssl-dev \
    zlib1g-dev \
  && mkdir -p /usr/local/etc/haproxy \
	&& make -j $(nproc) TARGET=linux-glibc USE_OPENSSL=1 USE_ZLIB=1 USE_PCRE=1 USE_PCRE_JIT=1 USE_EPOLL=1 USE_POLL= USE_BACKTRACE= USE_STATIC_PCRE=1
RUN mkdir -p /opt/ /opt/etc /opt/usr/sbin /opt/lib \
	&& cp /usr/src/haproxy/haproxy /opt/usr/sbin/haproxy \
  && cp --archive --parents /etc/passwd /opt \
  && cp --archive --parents /etc/group /opt \
  && cp --archive --parents /etc/shadow /opt \
  # hardening: remove unnecessary accounts \
  && sed --in-place --regexp-extended '/^(root|nobody)/!d' /opt/etc/group \
  && sed --in-place --regexp-extended '/^(root|nobody)/!d' /opt/etc/passwd \
  && sed --in-place --regexp-extended '/^(root|nobody)/!d' /opt/etc/shadow \
  # hardening: remove interactive shell \
  && sed --in-place --regexp-extended 's#^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):(.+)$#\1:\2:\3:\4:\5:\6:/bin/nologin#' /opt/etc/passwd \
  # hardening: lock all accounts
  #while IFS=: read -r user _; do passwd -l "$user"; done < /etc/passwd
  && cp --archive -H -r /etc/localtime /opt/etc/ \
  && cp --archive -H -r /lib/x86_64-linux-gnu/libcrypt.so.* /opt/lib \
  && cp --archive -H -r /lib/x86_64-linux-gnu/libz.so.* /opt/lib \
  && cp --archive -H -r /lib/x86_64-linux-gnu/libdl.so.* /opt/lib \
  && cp --archive -H -r /lib/x86_64-linux-gnu/librt.so.* /opt/lib \
  && cp --archive -H -r /usr/lib/x86_64-linux-gnu/libssl.so.* /opt/lib \
  && cp --archive -H -r /usr/lib/x86_64-linux-gnu/libcrypto.so.* /opt/lib \
  # libgcc_s.so.1 must be installed for pthread_cancel to work
  && cp --archive -H -r /usr/lib/gcc/x86_64-linux-gnu/8/libgcc_s.so.1 /opt/lib \
  && find /opt -executable -type f -exec strip --strip-all '{}' \; \
  && find /opt -executable -type f -exec upx '{}' \; \
  && chown -R root:root /opt \
  && find /opt -type d -exec chmod 0755 '{}' \; \
  && find /opt -type f -exec chmod 0644 '{}' \; \
  && chmod +x /opt/usr/sbin/haproxy

FROM busybox:1.32.1-glibc
ARG HAPROXY_VERSION=2.3.9
ARG BUILD_DATE
ARG VCS_REF
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.url="https://github.com/bc-interactive/docker-haproxy"
LABEL org.opencontainers.image.source="https://github.com/bc-interactive/docker-haproxy"
LABEL org.opencontainers.image.version="${HAPROXY_VERSION}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.vendor="bcinteractive"
LABEL org.opencontainers.image.title="haproxy"
LABEL org.opencontainers.image.authors="BC INTERACTIVE <contact@bc-interactive.fr>"
# https://www.haproxy.org/download/1.8/doc/management.txt
# "4. Stopping and restarting HAProxy"
# "when the SIGTERM signal is sent to the haproxy process, it immediately quits and all established connections are closed"
# "graceful stop is triggered when the SIGUSR1 signal is sent to the haproxy process"
COPY --from=builder /opt /
STOPSIGNAL SIGUSR1
EXPOSE 80 443
ENTRYPOINT ["/usr/sbin/haproxy"]
