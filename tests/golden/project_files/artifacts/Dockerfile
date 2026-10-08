FROM ubuntu:24.04
FROM alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa AS verified
FROM scratch
ENV DB_PASSWORD=correct-horse-battery-staple
ENV API_TOKEN=${API_TOKEN}
RUN chmod 777 /app
RUN chmod 755 /usr/local/bin/tool
ENV PATH=.:$PATH
ENV PATH=/opt/bin:$PATH
