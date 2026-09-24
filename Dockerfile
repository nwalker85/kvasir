FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /bin/kvasir-api ./cmd/kvasir-api

FROM alpine:3.21
RUN apk --no-cache add ca-certificates tzdata curl jq
COPY --from=builder /bin/kvasir-api /usr/local/bin/kvasir-api
RUN mkdir -p /var/lib/kvasir/receipts
ENV LISTEN_ADDR=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/kvasir-api"]
