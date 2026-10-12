FROM --platform=$BUILDPLATFORM golang:1.26.9-bookworm@sha256:d9c68c2c51161e12fd77e4c6320687c9cd86e1af1e3ad6e6cd63ff970641453c AS build

ENV GOTOOLCHAIN=local
WORKDIR /src
COPY app/ ./
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/greeter .


FROM build AS test
RUN go vet ./... && go test -race -count=1 ./...

FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
ARG VERSION=dev

ENV VERSION=$VERSION
LABEL org.opencontainers.image.title="greeter" \
      org.opencontainers.image.version=$VERSION
COPY --from=build /out/greeter /greeter
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/greeter"]
