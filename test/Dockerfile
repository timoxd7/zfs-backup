# Same userland as Raspberry Pi OS (Debian bookworm): bash 5.2, util-linux flock.
# Builds natively for arm64 on Apple Silicon, i.e. the Pi's architecture.
FROM debian:bookworm-slim
COPY fake-zfs /usr/local/bin/zfs
COPY fake-date /test/bin/date
COPY run-tests.sh /test/run-tests.sh
RUN chmod +x /usr/local/bin/zfs /test/bin/date /test/run-tests.sh
CMD ["/test/run-tests.sh"]
