# LoopCtrl relay: one static Go binary.
#   docker build -t loopctrl-relay connect/relay
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /loopctrl-relay .

FROM gcr.io/distroless/static-debian12:nonroot

LABEL org.opencontainers.image.title="loopctrl-relay" \
      org.opencontainers.image.description="LoopCtrl relay: invite enrollment and a reverse tunnel that gives each phone a public address" \
      org.opencontainers.image.source="https://github.com/Souitou-iop/LoopCtrl-Server" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --from=build /loopctrl-relay /loopctrl-relay
ENV LOOPCTRL_RELAY_LISTEN=0.0.0.0:8787 \
    LOOPCTRL_RELAY_STATE_FILE=/data/state.json
VOLUME ["/data"]
EXPOSE 8787
USER nonroot

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 CMD ["/loopctrl-relay", "-healthcheck"]

ENTRYPOINT ["/loopctrl-relay"]
