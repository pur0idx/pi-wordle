# Build context: repository root (needs data/words).
# Cross-compiles on the build machine's native arch, so multi-arch builds
# for the Pis do not run the Go compiler under QEMU.
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY services/word-service/go.mod ./
COPY services/word-service/*.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/word-service .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/word-service /word-service
COPY data/words /app/words
EXPOSE 8080
ENTRYPOINT ["/word-service"]
